import Darwin
import Foundation

// MARK: - Template placeholders

/// Placeholders an asset may contain. Every installed asset text is rendered
/// once at apply time with app-owned values; anything else is refused by the
/// manifest reader so a typo cannot ship verbatim.
enum Template {
    static let helperPath = "helperPath"
    static let marker = "marker"
    static let family = "family"
    static let target = "target"
    static let generation = "generation"

    static let allowed = [helperPath, marker, family, target, generation]

    static func values(
        marker: String,
        family: String,
        target: String,
        generation: UInt64,
        helperPath: String
    ) -> [String: String] {
        [
            Template.helperPath: helperPath,
            Template.marker: marker,
            Template.family: family,
            Template.target: target,
            Template.generation: String(generation)
        ]
    }

    /// Substitutes known placeholders in free text (TOML, YAML, text, and
    /// plugin sources) in one left-to-right scan. Values are escaped for a
    /// double-quoted context, which is where every bundled template places
    /// them.
    ///
    /// A substituted value is never rescanned: a value that itself contains
    /// another `{token}` stays literal instead of being expanded, so app-owned
    /// text (a path, a marker, a target) cannot inject a second placeholder
    /// into installed bytes.
    static func renderText(_ text: String, values: [String: String]) -> String {
        guard text.contains("{") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex
        while let open = text[index...].firstIndex(of: "{") {
            guard let close = text[open...].firstIndex(of: "}") else { break }
            let token = String(text[text.index(after: open)..<close])
            if allowed.contains(token), let value = values[token] {
                result += text[index..<open]
                result += escaped(value)
                index = text.index(after: close)
            } else {
                // Not a known placeholder with a value: keep the brace and
                // resume the scan after it. The remaining text is unchanged.
                result.append(contentsOf: text[index...open])
                index = text.index(after: open)
            }
        }
        result.append(contentsOf: text[index...])
        return result
    }

    /// Substitutes known placeholders inside string values and keys of a JSON
    /// asset, so the result is still valid JSON.
    static func renderJSON(_ value: JSONValue, values: [String: String]) -> JSONValue {
        switch value {
        case .object(let object):
            var result: [String: JSONValue] = [:]
            result.reserveCapacity(object.count)
            for (key, element) in object {
                result[renderText(key, values: values)] = renderJSON(element, values: values)
            }
            return .object(result)
        case .array(let array):
            return .array(array.map { renderJSON($0, values: values) })
        case .string(let string):
            return .string(renderText(string, values: values))
        case .number, .bool, .null:
            return value
        }
    }

    /// Returns the first `{token}` that is not an allowed placeholder, or
    /// `nil` when every brace-delimited identifier is known. Braces that do
    /// not enclose a bare identifier (object literals, blocks) are ignored.
    static func firstUnknownPlaceholder(in text: String) -> String? {
        var searchStart = text.startIndex
        while let open = text[searchStart...].firstIndex(of: "{") {
            guard let close = text[open...].firstIndex(of: "}") else { return nil }
            let inner = String(text[text.index(after: open)..<close])
            if isIdentifierToken(inner), !allowed.contains(inner) {
                return inner
            }
            searchStart = text.index(after: open)
        }
        return nil
    }

    /// Every rendered placeholder is gone from installed bytes.
    static func containsPlaceholder(_ text: String) -> Bool {
        allowed.contains { text.contains("{\($0)}") }
    }

    private static func isIdentifierToken(_ value: String) -> Bool {
        guard let first = value.first, first.isASCII, first.isLetter, !value.isEmpty else {
            return false
        }
        return value.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "_")
        }
    }

    private static func escaped(_ value: String) -> String {
        var result = ""
        for character in value {
            switch character {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default: result.append(character)
            }
        }
        return result
    }
}

// MARK: - Placeholder constants

enum IntegrationPaths {
    /// Documented default for the short-lived ingestion helper: the location
    /// `build.sh` signs inside a bundle installed in `/Applications`.
    ///
    /// It is a default, not the only source. Tests and a non-bundled context
    /// use it, while the app resolves the helper of its own running bundle
    /// with `HelperResolver` and passes that value into the installer, so a
    /// bundle built or copied anywhere else installs the path where its helper
    /// actually exists.
    static let helperPath = "/Applications/AwakeLite.app/Contents/MacOS/AwakeLiteHelper"

    /// File name `build.sh` gives the helper inside `Contents/MacOS`.
    static let helperExecutableName = "AwakeLiteHelper"
}

/// Resolves the helper executable that ships inside an app bundle.
///
/// The installer never guesses where its helper lives: the caller supplies the
/// path, and the app supplies the path of its own running bundle. The existence
/// check turns a bundle without a helper into a refusal instead of an installed
/// hook that can never run and fails silently.
enum HelperResolver {
    /// `bundleURL/Contents/MacOS/AwakeLiteHelper`, refusing when that path is
    /// absent or is not a regular file.
    static func resolve(
        appBundle bundleURL: URL,
        fileManager: FileManager = .default
    ) throws -> String {
        let executable = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(IntegrationPaths.helperExecutableName, isDirectory: false)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: executable.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw InstallerError.helperUnavailable(path: executable.path)
        }
        return executable.path
    }
}

// MARK: - File state

/// One file as the installer saw it. `sha256` is `nil` for a directory or a
/// missing file; equality on this value is what decides staleness, idempotency,
/// and whether rollback may overwrite.
struct FileState: Equatable {
    var exists: Bool
    var isDirectory: Bool
    var sha256: String?

    static let missing = FileState(exists: false, isDirectory: false, sha256: nil)
}

// MARK: - Config editor

/// Byte-level primitives for declarative edits. Nothing here knows a vendor
/// format beyond "JSON object", "marker block", and "app-owned file copy".
enum ConfigEditor {
    // MARK: Inspection

    /// `lstat` state of one path. A symlink is reported as a symlink rather
    /// than followed, so callers can refuse it.
    static func state(of url: URL) throws -> FileState {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return .missing }
            throw InstallerError.writeFailed(path: url.path, detail: String(cString: strerror(errno)))
        }
        let type = info.st_mode & S_IFMT
        if type == S_IFLNK { throw InstallerError.symlinked(path: url.path) }
        if type == S_IFDIR {
            return FileState(exists: true, isDirectory: true, sha256: nil)
        }
        guard type == S_IFREG else {
            throw InstallerError.unsafePath(path: url.path, detail: "not a regular file")
        }
        let data = try read(url)
        return FileState(exists: true, isDirectory: false, sha256: Digests.sha256(data))
    }

    /// Reads a regular file without following a final symlink.
    static func read(_ url: URL) throws -> Data {
        let descriptor = url.path.withCString {
            open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw InstallerError.writeFailed(path: url.path, detail: String(cString: strerror(errno)))
        }
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw InstallerError.writeFailed(path: url.path, detail: String(cString: strerror(errno)))
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw InstallerError.unsafePath(path: url.path, detail: "not a regular file")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw InstallerError.writeFailed(path: url.path, detail: String(cString: strerror(errno)))
            }
            if count == 0 { return data }
            data.append(contentsOf: buffer[0..<count])
        }
    }

    static func readIfPresent(_ url: URL) throws -> Data? {
        let state = try state(of: url)
        guard state.exists, !state.isDirectory else { return nil }
        return try read(url)
    }

    // MARK: Symlink checks

    /// Relative components of `url` below `root`, or `nil` when `url` is not
    /// inside it.
    static func relativeComponents(of url: URL, under root: URL) -> [String]? {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == rootPath { return [] }
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
    }

    /// Refuses a symlink anywhere from `root` down to `url`. Ancestors above
    /// the injected root are not inspected: the temporary home on macOS lives
    /// under `/var`, which is itself a symlink.
    static func verifyNoSymlink(_ url: URL, under root: URL) throws {
        guard let components = relativeComponents(of: url, under: root) else {
            throw InstallerError.unsafePath(
                path: url.path,
                detail: "outside the injected root \(root.path)"
            )
        }
        var current = root
        if !components.isEmpty {
            try refuseSymlink(current)
        }
        for component in components {
            current.appendPathComponent(component)
            var info = stat()
            guard lstat(current.path, &info) == 0 else { continue }
            if (info.st_mode & S_IFMT) == S_IFLNK {
                throw InstallerError.symlinked(path: current.path)
            }
        }
    }

    private static func refuseSymlink(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return }
        if (info.st_mode & S_IFMT) == S_IFLNK {
            throw InstallerError.symlinked(path: url.path)
        }
    }

    // MARK: Directories

    /// Creates `url` with mode 0700, recording every path it had to create.
    static func ensureDirectory(_ url: URL, created: inout [String]) throws {
        let manager = FileManager.default
        var isDirectory = ObjCBool(false)
        if manager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw InstallerError.unsafePath(path: url.path, detail: "expected a directory")
            }
            return
        }
        try ensureDirectory(url.deletingLastPathComponent(), created: &created)
        do {
            try manager.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw InstallerError.writeFailed(path: url.path, detail: error.localizedDescription)
        }
        created.append(url.path)
    }

    /// Creates the parent chain of a file, recording created directories.
    static func ensureParent(of url: URL, created: inout [String]) throws {
        try ensureDirectory(url.deletingLastPathComponent(), created: &created)
    }

    // MARK: Writing

    /// Replaces `url` by rename. Only bytes of this file change; a foreign
    /// file is never rewritten as a whole.
    ///
    /// An existing file keeps its permission bits, so editing a user's
    /// configuration does not tighten it behind their back; a new file gets
    /// `mode` (0600 by default).
    static func writeAtomically(
        _ data: Data,
        to url: URL,
        mode: mode_t = 0o600,
        preserveMode: Bool = true,
        fullSync: Bool = true
    ) throws {
        let directory = url.deletingLastPathComponent()
        sweepTemporaries(in: directory)
        var fileMode = mode
        if preserveMode {
            var existing = stat()
            if lstat(url.path, &existing) == 0, (existing.st_mode & S_IFMT) == S_IFREG {
                fileMode = existing.st_mode & 0o777
            }
        }
        let temporary = directory.appendingPathComponent(
            ".awake-lite-\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = temporary.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, fileMode)
        }
        guard descriptor >= 0 else {
            throw InstallerError.writeFailed(path: url.path, detail: String(cString: strerror(errno)))
        }
        var closed = false
        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            try handle.write(contentsOf: data)
            if fullSync, fcntl(descriptor, F_FULLFSYNC) != 0 {
                guard fsync(descriptor) == 0 else {
                    throw InstallerError.writeFailed(
                        path: url.path,
                        detail: String(cString: strerror(errno))
                    )
                }
            } else if !fullSync, fsync(descriptor) != 0 {
                throw InstallerError.writeFailed(
                    path: url.path,
                    detail: String(cString: strerror(errno))
                )
            }
            try handle.close()
            closed = true
            guard temporary.path.withCString({ source in
                url.path.withCString { target in rename(source, target) }
            }) == 0 else {
                throw InstallerError.writeFailed(
                    path: url.path,
                    detail: String(cString: strerror(errno))
                )
            }
            try syncDirectory(directory)
        } catch {
            if !closed { _ = Darwin.close(descriptor) }
            _ = temporary.path.withCString { unlink($0) }
            throw error
        }
    }

    /// Copies one app-owned asset file. The destination is written atomically;
    /// an existing foreign file is not merged, because the caller only copies
    /// into a path it owns.
    static func copyFile(from source: URL, to destination: URL) throws {
        let data = try read(source)
        try writeAtomically(data, to: destination)
    }

    /// Removes abandoned temporary files from an interrupted write. Only this
    /// editor's prefix is touched, and only when the file is not from a live
    /// writer.
    private static func sweepTemporaries(in directory: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-3600)
        for name in names where name.hasPrefix(".awake-lite-") && name.hasSuffix(".tmp") {
            let url = directory.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date()
            if modified < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Copies a bundled family directory (manifest and assets) into the
    /// installed package directory. These files are app-owned data, never
    /// user configuration.
    static func copyDirectoryContents(from source: URL, to destination: URL) throws {
        let manager = FileManager.default
        let entries = try manager.contentsOfDirectory(atPath: source.path).sorted()
        try manager.createDirectory(
            at: destination,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for entry in entries {
            let from = source.appendingPathComponent(entry)
            let to = destination.appendingPathComponent(entry)
            var info = stat()
            guard lstat(from.path, &info) == 0 else { continue }
            let type = info.st_mode & S_IFMT
            if type == S_IFLNK {
                throw InstallerError.symlinked(path: from.path)
            }
            if type == S_IFDIR {
                try copyDirectoryContents(from: from, to: to)
            } else if type == S_IFREG {
                try copyFile(from: from, to: to)
            }
        }
    }

    static func removeIfPresent(_ url: URL) throws {
        guard try state(of: url).exists else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw InstallerError.writeFailed(path: url.path, detail: error.localizedDescription)
        }
    }

    private static func syncDirectory(_ directory: URL) throws {
        let descriptor = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw InstallerError.writeFailed(
                path: directory.path,
                detail: String(cString: strerror(errno))
            )
        }
        defer { _ = Darwin.close(descriptor) }
        _ = fsync(descriptor)
    }
}

// MARK: - JSON mutation

/// Structural edits at one app-owned key. A foreign value is never replaced:
/// the caller decides ownership from the receipt, and this layer refuses to
/// descend into a scalar.
enum JSONMutation {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case nonContainer(keyPath: String)
        case missingContainer(keyPath: String)

        var description: String {
            switch self {
            case .nonContainer(let keyPath):
                return "path \(keyPath) is not an object"
            case .missingContainer(let keyPath):
                return "path \(keyPath) does not exist"
            }
        }
    }

    /// Value at `keyPath` + `marker`, or `nil` when the path or key is absent.
    static func value(in root: JSONValue, keyPath: [String], marker: String) throws -> JSONValue? {
        var current = root
        for segment in keyPath {
            guard let object = current.objectValue else {
                throw Failure.nonContainer(keyPath: segments(keyPath))
            }
            guard let next = object[segment] else { return nil }
            current = next
        }
        guard let object = current.objectValue else {
            throw Failure.nonContainer(keyPath: segments(keyPath))
        }
        return object[marker]
    }

    /// Returns `root` with `value` stored at `keyPath` + `marker`. Intermediate
    /// objects are created only where the path is absent; every other key and
    /// value is preserved.
    static func inserting(
        _ value: JSONValue,
        into root: JSONValue,
        keyPath: [String],
        marker: String
    ) throws -> JSONValue {
        try mutate(root, keyPath: keyPath) { object in
            var object = object
            object[marker] = value
            return .object(object)
        }
    }

    /// Returns `root` without the marker key, leaving foreign keys in place.
    static func removing(
        from root: JSONValue,
        keyPath: [String],
        marker: String
    ) throws -> JSONValue {
        try mutate(root, keyPath: keyPath) { object in
            var object = object
            object.removeValue(forKey: marker)
            return .object(object)
        }
    }

    /// Applies `transform` to the object found at `keyPath`, creating missing
    /// intermediate objects. A non-object segment is refused instead of being
    /// replaced.
    private static func mutate(
        _ root: JSONValue,
        keyPath: [String],
        transform: ([String: JSONValue]) -> JSONValue
    ) throws -> JSONValue {
        guard !keyPath.isEmpty else {
            guard let object = root.objectValue else {
                throw Failure.nonContainer(keyPath: segments(keyPath))
            }
            return transform(object)
        }
        return try mutate(root, remaining: keyPath, transform: transform)
    }

    private static func mutate(
        _ node: JSONValue,
        remaining: [String],
        transform: ([String: JSONValue]) -> JSONValue
    ) throws -> JSONValue {
        guard let container = node.objectValue else {
            throw Failure.nonContainer(keyPath: segments(remaining))
        }
        var object = container
        guard let head = remaining.first else { return transform(object) }
        let tail = Array(remaining.dropFirst())
        if tail.isEmpty {
            if let existing = object[head] {
                guard existing.objectValue != nil else {
                    throw Failure.nonContainer(keyPath: segments(remaining))
                }
                object[head] = try mutate(existing, remaining: [], transform: transform)
            } else {
                object[head] = try mutate(.object([:]), remaining: [], transform: transform)
            }
            return .object(object)
        }
        guard let existing = object[head] else {
            object[head] = try mutate(.object([:]), remaining: tail, transform: transform)
            return .object(object)
        }
        guard existing.objectValue != nil else {
            throw Failure.nonContainer(keyPath: segments(remaining))
        }
        object[head] = try mutate(existing, remaining: tail, transform: transform)
        return .object(object)
    }

    private static func segments(_ keyPath: [String]) -> String {
        keyPath.isEmpty ? "<root>" : keyPath.joined(separator: ".")
    }
}

// MARK: - Marker blocks

/// Marker-delimited block for TOML, YAML, and plain-text hook configuration.
///
/// The installer never rewrites bytes outside the block: install appends or
/// replaces exactly the block region, and removal deletes exactly that region.
enum MarkerBlock {
    static func beginLinePrefix(marker: String, prefix: String) -> String {
        "\(prefix) >>> awake-lite BEGIN \(marker)"
    }

    static func beginLine(marker: String, generation: UInt64, prefix: String) -> String {
        beginLinePrefix(marker: marker, prefix: prefix) + " generation=\(generation)"
    }

    static func endLine(marker: String, prefix: String) -> String {
        "\(prefix) <<< awake-lite END \(marker)"
    }

    static func text(marker: String, generation: UInt64, prefix: String, body: String) -> String {
        let trimmed = trimTrailingNewlines(body)
        return beginLine(marker: marker, generation: generation, prefix: prefix)
            + "\n" + trimmed + "\n"
            + endLine(marker: marker, prefix: prefix) + "\n"
    }

    enum Location: Equatable {
        /// No block and no stray marker line for this marker.
        case absent
        /// Exactly one well-formed block. `range` covers the block including
        /// the final newline; `body` is the bytes between the marker lines.
        case found(range: Range<String.Index>, body: String)
        /// A BEGIN or END marker for this marker without its counterpart, or
        /// an END before its BEGIN.
        case malformed
        /// More than one block for this marker.
        case duplicate
    }

    static func locate(in text: String, marker: String, prefix: String) -> Location {
        let beginPrefix = beginLinePrefix(marker: marker, prefix: prefix)
        let end = endLine(marker: marker, prefix: prefix)

        var lines: [(text: String, range: Range<String.Index>)] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let lineEnd = text[cursor...].firstIndex(of: "\n") ?? text.endIndex
            let next = lineEnd == text.endIndex ? text.endIndex : text.index(after: lineEnd)
            lines.append((String(text[cursor..<lineEnd]), cursor..<next))
            cursor = next
        }

        var begins: [Int] = []
        var ends: [Int] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(beginPrefix) { begins.append(index) }
            if trimmed == end { ends.append(index) }
        }

        if begins.isEmpty { return ends.isEmpty ? .absent : .malformed }
        if begins.count > 1 || ends.count > 1 { return .duplicate }
        guard let begin = begins.first, let finish = ends.first else { return .malformed }
        guard finish > begin else { return .malformed }
        for index in (begin + 1)..<finish {
            let trimmed = lines[index].text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(beginPrefix) || trimmed == end { return .malformed }
        }
        let bodyStart = lines[begin].range.upperBound
        let bodyEnd = lines[finish].range.lowerBound
        let body = String(text[bodyStart..<bodyEnd])
        return .found(
            range: lines[begin].range.lowerBound..<lines[finish].range.upperBound,
            body: trimTrailingNewlines(body)
        )
    }

    /// Appends the block, or replaces only the existing block for this marker.
    /// Returns the new file text and whether anything changed.
    static func applying(
        _ block: String,
        to text: String,
        marker: String,
        prefix: String
    ) throws -> (text: String, changed: Bool) {
        switch locate(in: text, marker: marker, prefix: prefix) {
        case .absent:
            var result = text
            if !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
            result += block
            return (result, true)
        case .found(let range, _):
            let existing = String(text[range])
            if existing == block { return (text, false) }
            var result = text
            result.replaceSubrange(range, with: block)
            return (result, true)
        case .malformed:
            throw InstallerError.conflict(
                summary: "malformed awake-lite block for marker \"\(marker)\""
            )
        case .duplicate:
            throw InstallerError.conflict(
                summary: "duplicate awake-lite blocks for marker \"\(marker)\""
            )
        }
    }

    /// Removes only the block for this marker. Returns whether a block existed.
    static func removing(
        from text: String,
        marker: String,
        prefix: String
    ) throws -> (text: String, removed: Bool) {
        switch locate(in: text, marker: marker, prefix: prefix) {
        case .absent:
            return (text, false)
        case .found(let range, _):
            var result = text
            result.removeSubrange(range)
            return (result, true)
        case .malformed:
            throw InstallerError.conflict(
                summary: "malformed awake-lite block for marker \"\(marker)\""
            )
        case .duplicate:
            throw InstallerError.conflict(
                summary: "duplicate awake-lite blocks for marker \"\(marker)\""
            )
        }
    }

    static func bodyHash(_ body: String) -> String {
        Digests.sha256(body)
    }

    private static func trimTrailingNewlines(_ value: String) -> String {
        var result = value
        while result.hasSuffix("\n") { result.removeLast() }
        return result
    }
}
