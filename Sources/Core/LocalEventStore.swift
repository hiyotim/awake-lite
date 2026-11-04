import Darwin
import Foundation

/// Bounded, crash-safe storage for normalized activity events.
///
/// Helpers write immutable event files into `inbox/`; the app owns
/// `checkpoint.json`. A reconcile pass applies inbox events to the model,
/// persists the checkpoint, and only then deletes the processed files. A crash
/// between those steps replays events as duplicates instead of losing facts.
struct LocalEventStore {
    struct Limits: Equatable {
        var maxInboxFiles = 2048
        var maxEventBytes = 64 * 1024
        var maxEventsPerPass = 512
        var maxRejectedFiles = 64
    }

    /// Versioned envelope around the model. A checkpoint always states the
    /// schema that produced it, so a future version is rejected explicitly
    /// instead of decoding as an empty model.
    struct Checkpoint: Codable {
        static let currentSchema = 1

        var schema: Int
        var model: ActivityModel
    }

    /// A checkpoint larger than this is corrupt by construction.
    static let maxCheckpointBytes = 16 * 1024 * 1024
    /// Leftover temporary files younger than this may belong to a live writer.
    static let staleTemporaryAge: TimeInterval = 3600
    /// Stamps further ahead than this say nothing about observed order.
    static let futureTolerance: TimeInterval = 300

    let root: URL
    var limits: Limits

    init(root: URL, limits: Limits = Limits()) {
        self.root = root
        self.limits = limits
    }

    var inbox: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    var rejected: URL { root.appendingPathComponent("rejected", isDirectory: true) }
    var checkpoint: URL { root.appendingPathComponent("checkpoint.json") }
    var lock: URL { root.appendingPathComponent(".lock") }

    // MARK: - Directories

    /// Creates any missing directory with owner-only access and sweeps
    /// temporary files abandoned by an interrupted writer. Existing
    /// directories are left exactly as the user has them.
    func prepare() throws {
        let manager = FileManager.default
        for directory in [root, inbox, rejected] {
            var isDirectory = ObjCBool(false)
            if manager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                continue
            }
            do {
                try manager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw StoreError.writeFailed(error.localizedDescription)
            }
        }
        sweepTemporaries(in: [root, inbox, rejected])
    }

    private func sweepTemporaries(in directories: [URL]) {
        let manager = FileManager.default
        let cutoff = Date().addingTimeInterval(-Self.staleTemporaryAge)
        for directory in directories {
            let entries = (try? manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: []
            )) ?? []
            for file in entries {
                let name = file.lastPathComponent
                guard name.hasPrefix("."), name.hasSuffix(".tmp") else { continue }
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? Date()
                if modified < cutoff {
                    try? manager.removeItem(at: file)
                }
            }
        }
    }

    // MARK: - Checkpoint

    /// Loads the app-owned checkpoint. A missing file is an empty model; a
    /// corrupt, oversized, non-regular, or future-schema file never silently
    /// resets state.
    func loadModel() throws -> ActivityModel {
        let path = checkpoint.path
        // O_NOFOLLOW plus a regular-file check keeps a symlink or directory
        // from being read as state.
        let descriptor = path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else {
            if errno == ENOENT { return ActivityModel() }
            throw StoreError.invalidCheckpoint(path)
        }
        defer { _ = Darwin.close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw StoreError.invalidCheckpoint(path)
        }
        guard info.st_size <= Self.maxCheckpointBytes else {
            throw StoreError.invalidCheckpoint(path)
        }

        let data: Data
        do {
            data = try readAll(from: descriptor)
        } catch {
            throw StoreError.invalidCheckpoint(path)
        }

        let decoded: Checkpoint
        do {
            decoded = try JSONDecoder().decode(Checkpoint.self, from: data)
        } catch {
            throw StoreError.invalidCheckpoint(path)
        }
        guard decoded.schema == Checkpoint.currentSchema else {
            throw StoreError.unsupportedCheckpoint(path, decoded.schema)
        }
        return decoded.model
    }

    /// Persists the model atomically under the writer lock.
    func saveModel(_ model: ActivityModel) throws {
        try prepare()
        let descriptor = try acquireLock()
        defer { releaseLock(descriptor) }
        try saveModelUnlocked(model)
    }

    /// Caller already holds the writer lock.
    func saveModelUnlocked(_ model: ActivityModel) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(Checkpoint(schema: Checkpoint.currentSchema, model: model))
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
        try writeAtomically(data, to: checkpoint, mode: 0o600, fullSync: true)
    }

    // MARK: - Inbox producers

    /// Writes one immutable event file. Used by tests and by the native helper.
    ///
    /// Identifiers must already be canonical: the file name is derived from
    /// them, so a value that sanitizing would change is refused rather than
    /// silently aliased. Re-enqueuing the exact same event is idempotent — the
    /// stored bytes are already identical — while a different payload under an
    /// existing name is refused rather than merged.
    func enqueue(_ event: ActivityEvent) throws {
        try prepare()
        guard EventFileName.sanitize(event.source) == event.source,
              EventFileName.sanitize(event.session.instance) == event.session.instance,
              EventFileName.sanitize(event.id) == event.id else {
            throw StoreError.invalidIdentifier
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(event)
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
        guard data.count <= limits.maxEventBytes else {
            throw StoreError.eventTooLarge
        }

        let name = EventFileName.make(event: event, at: event.timestamp)
        try writeLinked(data, named: name, in: inbox, mode: 0o600)
    }

    /// Creates the event file without ever replacing an existing one: the
    /// written temporary file is hard-linked into place, so a concurrent
    /// writer cannot overwrite a fact.
    ///
    /// A name that already exists is compared byte-for-byte with the candidate.
    /// Identical content is the same event arriving twice (a retry, or two
    /// producers emitting the same normalized event), so it is an idempotent
    /// replay: success and no new file. Different content under one name would
    /// silently merge two facts — a reused identifier, or a case-insensitive
    /// volume folding two IDs — so it is refused instead of suffixed into a
    /// second file the model would treat as the same observation.
    private func writeLinked(_ data: Data, named name: String, in directory: URL, mode: mode_t) throws {
        let temporary = try writeTemporaryFile(data, in: directory, name: name, mode: mode)
        defer { _ = temporary.path.withCString { unlink($0) } }

        let destination = directory.appendingPathComponent(name)
        for _ in 0..<8 {
            let result = temporary.path.withCString { source in
                destination.path.withCString { target in
                    link(source, target)
                }
            }
            if result == 0 {
                // The link is durable once the directory entry is; the temp
                // name must not survive it.
                _ = temporary.path.withCString { unlink($0) }
                try syncDirectory(directory)
                return
            }
            guard errno == EEXIST else { throw StoreError.posix(errno) }

            guard let existing = try readExistingEvent(at: destination) else {
                // The occupant vanished between the link attempt and the read;
                // the name is free again, so try once more.
                continue
            }
            guard existing == data else {
                throw StoreError.writeFailed(Self.conflictingEventDetail)
            }
            // The exact event is already stored: this write is a replay, so it
            // succeeded without adding a file.
            return
        }
        throw StoreError.posix(EEXIST)
    }

    /// Detail for two different payloads competing for one event name.
    private static let conflictingEventDetail =
        "an event with the same identifier already exists with different content"

    /// Reads the file already occupying an event name. `nil` means it vanished,
    /// so the caller can retry the link. A non-regular, symlinked, or oversized
    /// occupant cannot be the candidate, which the caller then refuses.
    private func readExistingEvent(at url: URL) throws -> Data? {
        // O_NOFOLLOW keeps a symlink from being read as stored evidence.
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw StoreError.posix(errno)
        }
        defer { _ = Darwin.close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= off_t(limits.maxEventBytes)
        else {
            throw StoreError.writeFailed(Self.conflictingEventDetail)
        }
        return try readAll(from: descriptor)
    }

    // MARK: - Reconciliation

    /// Applies a bounded batch of inbox events to `model`.
    ///
    /// The checkpoint is saved before any file is moved or deleted. Rejected
    /// files move to `rejected/` and leave an `eventRejected` gap. An inbox
    /// above its file bound leaves a `storageOverflow` gap for every affected
    /// scope; neither condition permits a confirmed-idle claim.
    func reconcile(_ model: inout ActivityModel, deletingProcessed: Bool = true) throws -> ReconcileReport {
        try prepare()
        let lockDescriptor = try acquireLock()
        defer { releaseLock(lockDescriptor) }

        let manager = FileManager.default
        var report = ReconcileReport()
        let names = try manager.contentsOfDirectory(atPath: inbox.path)
            .filter { $0.hasSuffix(".event") }
            .sorted()

        if names.count > limits.maxInboxFiles {
            report.overflowed = true
            let now = Date()
            var scopes = Set<GapKey>()
            for name in names {
                guard let scope = EventFileName.scope(of: name) else { continue }
                scopes.insert(GapKey(family: scope.family, instance: scope.instance, session: nil))
            }
            for key in scopes.sorted(by: { ($0.family, $0.instance) < ($1.family, $1.instance) }) {
                model.recordGap(
                    family: key.family,
                    instance: key.instance,
                    session: nil,
                    reason: .storageOverflow,
                    at: now
                )
            }
        }

        var processed: [URL] = []
        // Rejected files stay in the inbox until the checkpoint is saved, so a
        // failed save cannot lose the evidence that produced the gap.
        var pendingRejected: [URL] = []

        for name in names.prefix(max(0, limits.maxEventsPerPass)) {
            let file = inbox.appendingPathComponent(name)
            guard let scope = EventFileName.scope(of: name) else {
                model.recordGap(
                    family: "",
                    instance: "",
                    session: nil,
                    reason: .eventRejected,
                    at: rejectionTime(for: file)
                )
                pendingRejected.append(file)
                report.rejectedFiles += 1
                continue
            }

            let size: Int
            do {
                let attributes = try manager.attributesOfItem(atPath: file.path)
                size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            } catch {
                if !manager.fileExists(atPath: file.path) { continue }
                reject(
                    file,
                    scope: scope,
                    session: nil,
                    model: &model,
                    pending: &pendingRejected,
                    report: &report
                )
                continue
            }
            if size > limits.maxEventBytes {
                reject(
                    file,
                    scope: scope,
                    session: nil,
                    model: &model,
                    pending: &pendingRejected,
                    report: &report
                )
                continue
            }

            let event: ActivityEvent
            do {
                let data = try Data(contentsOf: file)
                event = try JSONDecoder().decode(ActivityEvent.self, from: data)
            } catch {
                reject(
                    file,
                    scope: scope,
                    session: nil,
                    model: &model,
                    pending: &pendingRejected,
                    report: &report
                )
                continue
            }

            guard scope.family == EventFileName.sanitize(event.source),
                  scope.instance == EventFileName.sanitize(event.session.instance) else {
                reject(
                    file,
                    scope: scope,
                    session: nil,
                    model: &model,
                    pending: &pendingRejected,
                    report: &report
                )
                continue
            }

            // A stamp far in the future is not a fact this store can order
            // against anything else it holds.
            guard event.timestamp <= Date().addingTimeInterval(Self.futureTolerance) else {
                reject(
                    file,
                    scope: (event.source, event.session.instance),
                    session: event.session.session,
                    model: &model,
                    pending: &pendingRejected,
                    report: &report
                )
                continue
            }

            switch model.apply(event) {
            case .applied:
                report.applied += 1
            case .duplicate:
                report.duplicates += 1
            case .ignored(let reason):
                report.ignored[reason.rawValue, default: 0] += 1
                // Only outcomes that mean the observation was not understood
                // leave a gap; ordering and ownership rejections are expected
                // noise, and capacity already recorded its own gap. A
                // heartbeat is a liveness beat, not a claim about work, so an
                // unknown target must not pin the aggregate to unknown.
                let livenessOnly = reason == .unknownWork && event.transition == .heartbeat
                if Self.rejectionReasons.contains(reason), !livenessOnly {
                    model.recordGap(
                        family: event.source,
                        instance: event.session.instance,
                        session: event.session.session,
                        reason: .eventRejected,
                        at: event.timestamp
                    )
                }
            }
            processed.append(file)
            report.processedFiles += 1
        }

        let changed = report.overflowed || !processed.isEmpty || report.rejectedFiles > 0
        if changed {
            do {
                try saveModelUnlocked(model)
            } catch {
                // Nothing moved yet: every inbox file stays where it was and
                // the pass is retried later.
                try? pruneRejected()
                throw error
            }
        }

        do {
            for file in pendingRejected {
                try moveToRejected(file)
            }
        } catch {
            try? pruneRejected()
            throw error
        }

        if deletingProcessed {
            for file in processed {
                let result = file.path.withCString { unlink($0) }
                if result == 0 { continue }
                // A file already gone is a completed deletion.
                if errno == ENOENT { continue }
                report.deleteFailures += 1
            }
        }

        try pruneRejected()
        return report
    }

    /// Outcomes that mean the observation was not understood.
    private static let rejectionReasons: Set<IgnoreReason> = [
        .unsupportedSchema, .unknownWork, .invalidSnapshot
    ]

    // MARK: - Rejection

    private func reject(
        _ file: URL,
        scope: (family: String, instance: String),
        session: String?,
        model: inout ActivityModel,
        pending: inout [URL],
        report: inout ReconcileReport
    ) {
        model.recordGap(
            family: scope.family,
            instance: scope.instance,
            session: session,
            reason: .eventRejected,
            at: rejectionTime(for: file)
        )
        pending.append(file)
        report.rejectedFiles += 1
    }

    /// Time of the loss as the inbox recorded it. The helper's own clock is a
    /// last resort: a replay after a crash must land on the same date.
    private func rejectionTime(for file: URL) -> Date {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        if let created = attributes?[.creationDate] as? Date { return created }
        if let modified = attributes?[.modificationDate] as? Date { return modified }
        return Date()
    }

    private func moveToRejected(_ file: URL) throws {
        let manager = FileManager.default
        var destination = rejected.appendingPathComponent(file.lastPathComponent)
        // Never overwrite retained evidence.
        if manager.fileExists(atPath: destination.path) {
            destination = rejected.appendingPathComponent(Self.uniqueName(for: file.lastPathComponent))
            guard !manager.fileExists(atPath: destination.path) else {
                throw StoreError.posix(EEXIST)
            }
        }
        let result = file.path.withCString { source in
            destination.path.withCString { target in
                rename(source, target)
            }
        }
        guard result == 0 else { throw StoreError.posix(errno) }
    }

    /// Keeps the rejected directory bounded, dropping the oldest files first.
    private func pruneRejected() throws {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(
            at: rejected,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        guard files.count > limits.maxRejectedFiles else { return }

        let sorted = files.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if left == right { return lhs.lastPathComponent < rhs.lastPathComponent }
            return left < right
        }
        for file in sorted.prefix(files.count - limits.maxRejectedFiles) {
            try? manager.removeItem(at: file)
        }
    }

    /// Appends `-<8 hex>` before `.event`, keeping the name unique without
    /// changing its parsed scope.
    static func uniqueName(for name: String) -> String {
        let suffix = String(format: "%08x", UInt32.random(in: UInt32.min...UInt32.max))
        let base = name.hasSuffix(".event") ? String(name.dropLast(6)) : name
        return "\(base)-\(suffix).event"
    }

    // MARK: - Writer lock

    /// One exclusive, non-blocking writer at a time. A busy store is an error,
    /// not a reason to skip the pass silently.
    private func acquireLock() throws -> Int32 {
        let descriptor = lock.path.withCString {
            open($0, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else { throw StoreError.posix(errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            throw code == EWOULDBLOCK ? StoreError.locked : StoreError.posix(code)
        }
        return descriptor
    }

    private func releaseLock(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
    }

    // MARK: - Atomic writes

    /// Writes `data` to a fresh hidden file in `directory` and returns it.
    /// The caller unlinks it once the file has been linked or renamed into
    /// place.
    private func writeTemporaryFile(
        _ data: Data,
        in directory: URL,
        name: String,
        mode: mode_t,
        fullSync: Bool = false
    ) throws -> URL {
        let temporary = directory.appendingPathComponent(
            ".\(name).\(UUID().uuidString).tmp"
        )
        let descriptor = temporary.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        }
        guard descriptor >= 0 else { throw StoreError.posix(errno) }

        var closed = false
        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            do {
                try handle.write(contentsOf: data)
            } catch {
                throw StoreError.writeFailed(error.localizedDescription)
            }
            try synchronize(descriptor, fullSync: fullSync)
            do {
                try handle.close()
                closed = true
            } catch {
                throw StoreError.writeFailed(error.localizedDescription)
            }
            return temporary
        } catch {
            if !closed { _ = Darwin.close(descriptor) }
            _ = temporary.path.withCString { unlink($0) }
            throw error
        }
    }

    /// Replaces the checkpoint by rename, which is safe because the caller
    /// holds the writer lock and a torn checkpoint is unusable by design.
    private func writeAtomically(
        _ data: Data,
        to destination: URL,
        mode: mode_t,
        fullSync: Bool = false
    ) throws {
        let directory = destination.deletingLastPathComponent()
        let temporary = try writeTemporaryFile(
            data,
            in: directory,
            name: destination.lastPathComponent,
            mode: mode,
            fullSync: fullSync
        )
        defer { _ = temporary.path.withCString { unlink($0) } }

        let renamed = temporary.path.withCString { source in
            destination.path.withCString { target in
                rename(source, target)
            }
        }
        guard renamed == 0 else { throw StoreError.posix(errno) }
        try syncDirectory(directory)
    }

    /// F_FULLFSYNC flushes the drive cache as well as the file; a filesystem
    /// that rejects it still gets an ordinary fsync.
    private func synchronize(_ descriptor: Int32, fullSync: Bool) throws {
        if fullSync, fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard fsync(descriptor) == 0 else { throw StoreError.posix(errno) }
    }

    private func syncDirectory(_ directory: URL) throws {
        let descriptor = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw StoreError.posix(errno) }
        defer { _ = Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw StoreError.posix(errno) }
    }

    private func readAll(from descriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw StoreError.posix(errno)
            }
            if count == 0 { return data }
            data.append(contentsOf: buffer[0..<count])
            if data.count > Self.maxCheckpointBytes { throw StoreError.posix(EFBIG) }
        }
    }
}

// MARK: - File names

/// Encodes identity into a safe file name and parses it back.
///
/// Names sort lexicographically by timestamp, so an inbox listing is already
/// in observation order. No raw identifier ever reaches a path component.
enum EventFileName {
    static func make(event: ActivityEvent, at date: Date) -> String {
        let micros = UInt64(max(0, (date.timeIntervalSince1970 * 1_000_000).rounded(.down)))
        let stamp = String(format: "%020llu", micros)
        return "\(sanitize(event.source))@\(sanitize(event.session.instance))@\(stamp)@\(sanitize(event.id)).event"
    }

    /// Parses the family and instance out of a name produced by `make`.
    ///
    /// Anything that is not exactly `family@instance@<20-digit micros>@id` is
    /// not an event this store wrote.
    static func scope(of name: String) -> (family: String, instance: String)? {
        let base = name.hasSuffix(".event") ? String(name.dropLast(6)) : name
        let parts = base.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        guard parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        let stamp = parts[2]
        guard stamp.count == 20, stamp.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// Keeps `[A-Za-z0-9_-]`, replaces everything else with `_`, caps at 64
    /// characters, and never returns an empty component.
    static func sanitize(_ value: String) -> String {
        var result = ""
        var written = 0
        for scalar in value.unicodeScalars {
            if written == 64 { break }
            let code = scalar.value
            let keeps = (0x30...0x39).contains(code)
                || (0x41...0x5A).contains(code)
                || (0x61...0x7A).contains(code)
                || code == 0x5F
                || code == 0x2D
            if keeps {
                result.unicodeScalars.append(scalar)
            } else {
                result.append("_")
            }
            written += 1
        }
        return result.isEmpty ? "_" : result
    }
}

// MARK: - Reports and errors

struct ReconcileReport: Equatable {
    var applied = 0
    var duplicates = 0
    var ignored: [String: Int] = [:]
    var rejectedFiles = 0
    var overflowed = false
    var processedFiles = 0
    /// Processed files whose deletion failed; the pass continues without them.
    var deleteFailures = 0
}

enum StoreError: Error, Equatable {
    case writeFailed(String)
    case posix(Int32)
    case invalidCheckpoint(String)
    case unsupportedCheckpoint(String, Int)
    case invalidIdentifier
    case eventTooLarge
    case locked
}
