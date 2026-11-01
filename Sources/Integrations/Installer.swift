import Darwin
import Foundation

// MARK: - Errors

enum InstallerError: Error, Equatable, CustomStringConvertible {
    case unknownFamily(String)
    case noReceipt(family: String)
    case stalePreview(String)
    case blockedByRecovery(operationId: String)
    case conflict(summary: String)
    case conflicts([String])
    case unsupportedFormat(step: Int, format: StepFormat, detail: String)
    case invalidPlan(String)
    case invalidAsset(id: String, detail: String)
    case unsafePath(path: String, detail: String)
    case symlinked(path: String)
    case malformedJSON(path: String, detail: String)
    case receiptUnreadable(path: String, detail: String)
    case journalUnreadable(path: String, detail: String)
    case writeFailed(path: String, detail: String)

    var description: String {
        switch self {
        case .unknownFamily(let family):
            return "unknown integration family \"\(family)\""
        case .noReceipt(let family):
            return "integration \"\(family)\" is not installed"
        case .stalePreview(let detail):
            return "preview is stale: \(detail)"
        case .blockedByRecovery(let operationId):
            return "operation \(operationId) still needs recovery; resolve it before starting a new operation"
        case .conflict(let summary):
            return "conflict: \(summary)"
        case .conflicts(let conflicts):
            return "conflicts: " + conflicts.joined(separator: "; ")
        case .unsupportedFormat(let step, let format, let detail):
            return "manifest step \(step): unsupported format \"\(format.rawValue)\": \(detail)"
        case .invalidPlan(let detail):
            return "invalid install plan: \(detail)"
        case .invalidAsset(let id, let detail):
            return "asset \"\(id)\": \(detail)"
        case .unsafePath(let path, let detail):
            return "unsafe path \(path): \(detail)"
        case .symlinked(let path):
            return "refusing to edit \(path): a symlink is present on the path"
        case .malformedJSON(let path, let detail):
            return "refusing to edit \(path): malformed JSON (\(detail))"
        case .receiptUnreadable(let path, let detail):
            return "receipt \(path) cannot be read: \(detail)"
        case .journalUnreadable(let path, let detail):
            return "journal \(path) cannot be read: \(detail)"
        case .writeFailed(let path, let detail):
            return "cannot write \(path): \(detail)"
        }
    }
}

// MARK: - Journal

/// One reversible mutation. Registered before the mutation and completed after
/// it, so a crash in between is recoverable.
struct JournalStep: Codable, Equatable {
    /// `config`, `obsolete`, or `package`.
    var operation: String
    var target: String
    var path: String
    var beforeHash: String?
    var afterHash: String?
    /// Used only by the app-owned package directory step.
    var backupPath: String?
    var applied: Bool
    /// The path did not exist before this operation, so rollback deletes it.
    var created: Bool
    /// How to undo this step. Only app-owned template text is stored, so a
    /// shared configuration file is never copied into app storage.
    var undo: JournalUndo?
}

/// A reversible instruction using app-owned content only: rendered asset text,
/// never user configuration or conversation bytes.
struct JournalUndo: Codable, Equatable {
    enum Kind: String, Codable {
        case removeJSONEntries
        case restoreJSONEntries
        case removeBlocks
        case restoreBlocks
        case deleteFile
        case restoreFile
    }

    var kind: Kind
    var keyPath: [String]?
    var prefix: String?
    /// Markers, parallel to `texts`.
    var markers: [String]?
    /// Canonical JSON values for `restoreJSONEntries`, or block/file text.
    var texts: [String]?
}

/// Schema-1 operation journal: lifecycle metadata only.
struct OperationJournal: Codable, Equatable {
    static let currentSchema = 1

    var schema: Int
    var operationId: String
    var family: String
    var action: InstallAction
    var stage: InstallStage
    var startedAt: Date
    var steps: [JournalStep]
    var createdPaths: [String]
    /// How many configuration mutations this operation intends to record.
    var expectedMutations: Int
    /// Receipt to write when the recorded mutation set is complete.
    var receipt: InstallReceipt?
}

// MARK: - Reports

enum RecoveryOutcome: String, Equatable {
    case forwardCommitted
    case rolledBack
    case recoveryRequired
}

struct RecoveryReport: Equatable {
    var operationId: String
    var family: String
    var action: InstallAction
    var outcome: RecoveryOutcome
    var conflicts: [String]
}

struct RemovalReport: Equatable {
    var family: String
    var removedPaths: [String]
    var preservedPaths: [String]
    var warnings: [String]
}

/// Test seam for crash simulation. Production always passes `nil`.
typealias FaultInjector = (InstallerFaultPoint) throws -> Void

enum InstallerFaultPoint: Equatable {
    case journalWritten
    case beforeStep(Int)
    case afterStep(Int)
    case beforeReceipt
    case afterReceipt
}

// MARK: - Storage

/// App-owned storage under the injected support root.
struct InstallerStorage {
    let root: URL

    var packages: URL { root.appendingPathComponent("packages", isDirectory: true) }
    var receipts: URL { root.appendingPathComponent("receipts", isDirectory: true) }
    var journal: URL { root.appendingPathComponent("journal", isDirectory: true) }
    var backups: URL { journal.appendingPathComponent("backups", isDirectory: true) }

    func receiptPath(family: String) -> URL {
        receipts.appendingPathComponent("\(family).json")
    }

    func journalPath(operationId: String) -> URL {
        journal.appendingPathComponent("\(operationId).json")
    }

    func packagePath(family: String) -> URL {
        packages.appendingPathComponent(family, isDirectory: true)
    }

    func backupPath(operationId: String, index: Int) -> URL {
        backups
            .appendingPathComponent(operationId, isDirectory: true)
            .appendingPathComponent(String(format: "%03d", index))
    }

    func exists() -> Bool {
        var isDirectory = ObjCBool(false)
        let present = FileManager.default.fileExists(
            atPath: root.path,
            isDirectory: &isDirectory
        )
        return present && isDirectory.boolValue
    }

    /// Creates the root and its subdirectories with owner-only access. Existing
    /// directories are left as the user has them.
    func prepare() throws {
        var created: [String] = []
        for directory in [root, packages, receipts, journal, backups] {
            try ConfigEditor.ensureDirectory(directory, created: &created)
        }
    }

    // MARK: Receipts

    func loadReceipt(family: String) throws -> InstallReceipt? {
        let url = receiptPath(family: family)
        let state = try ConfigEditor.state(of: url)
        guard state.exists else { return nil }
        guard !state.isDirectory, let data = try ConfigEditor.readIfPresent(url) else {
            throw InstallerError.receiptUnreadable(path: url.path, detail: "not a regular file")
        }
        do {
            let receipt = try JSONDecoder().decode(InstallReceipt.self, from: data)
            guard receipt.schema == InstallReceipt.currentSchema else {
                throw InstallerError.receiptUnreadable(
                    path: url.path,
                    detail: "unsupported schema \(receipt.schema)"
                )
            }
            guard receipt.family == family else {
                throw InstallerError.receiptUnreadable(
                    path: url.path,
                    detail: "family \"\(receipt.family)\" does not match the file name"
                )
            }
            return receipt
        } catch let error as InstallerError {
            throw error
        } catch {
            throw InstallerError.receiptUnreadable(path: url.path, detail: error.localizedDescription)
        }
    }

    func saveReceipt(_ receipt: InstallReceipt) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let url = receiptPath(family: receipt.family)
        let data: Data
        do {
            data = try encoder.encode(receipt)
        } catch {
            throw InstallerError.writeFailed(path: url.path, detail: error.localizedDescription)
        }
        try ConfigEditor.writeAtomically(data, to: url)
    }

    func deleteReceipt(family: String) throws {
        try ConfigEditor.removeIfPresent(receiptPath(family: family))
    }

    // MARK: Journals

    func loadJournals() throws -> [OperationJournal] {
        guard exists() else { return [] }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: journal.path)
                .filter { $0.hasSuffix(".json") }
                .sorted()
        } catch {
            throw InstallerError.writeFailed(path: journal.path, detail: error.localizedDescription)
        }
        var result: [OperationJournal] = []
        for name in names {
            let url = journal.appendingPathComponent(name)
            guard let data = try ConfigEditor.readIfPresent(url) else { continue }
            do {
                let journal = try JSONDecoder().decode(OperationJournal.self, from: data)
                guard journal.schema == OperationJournal.currentSchema else {
                    throw InstallerError.journalUnreadable(
                        path: url.path,
                        detail: "unsupported schema \(journal.schema)"
                    )
                }
                guard "\(journal.operationId).json" == name else {
                    throw InstallerError.journalUnreadable(
                        path: url.path,
                        detail: "operation id does not match the file name"
                    )
                }
                result.append(journal)
            } catch let error as InstallerError {
                throw error
            } catch {
                throw InstallerError.journalUnreadable(
                    path: url.path,
                    detail: error.localizedDescription
                )
            }
        }
        return result
    }

    func writeJournal(_ journal: OperationJournal) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let url = journalPath(operationId: journal.operationId)
        let data: Data
        do {
            data = try encoder.encode(journal)
        } catch {
            throw InstallerError.writeFailed(path: url.path, detail: error.localizedDescription)
        }
        try ConfigEditor.writeAtomically(data, to: url)
    }

    func deleteJournal(operationId: String) throws {
        try ConfigEditor.removeIfPresent(journalPath(operationId: operationId))
        let backup = backups.appendingPathComponent(operationId, isDirectory: true)
        try? FileManager.default.removeItem(at: backup)
    }
}

// MARK: - Installer

/// Declarative installation over the catalog.
///
/// Owns previews, owned configuration edits, receipts, the operation journal,
/// rollback, and recovery. It never parses vendor payloads, never holds power
/// policy, never runs a subprocess, and cannot express a vendor hook shape
/// beyond the markers a manifest declares.
struct Installer {
    var catalog: Catalog
    var helperPath: String
    var faults: FaultInjector?

    init(catalog: Catalog, helperPath: String = IntegrationPaths.helperPath, faults: FaultInjector? = nil) {
        self.catalog = catalog
        self.helperPath = helperPath
        self.faults = faults
    }

    // MARK: Preview

    /// Reads current configuration and plans an installation. Writes nothing.
    ///
    /// `configRoot` is the injected home root: `~` and `$HOME` selectors in a
    /// step resolve here, so a test never touches the real home directory.
    func preview(
        family: String,
        configRoot: URL,
        appSupportRoot: URL,
        discovery: ProductDiscovery? = nil
    ) throws -> InstallPreview {
        let manifest = try catalog.manifest(for: family)
        let storage = InstallerStorage(root: appSupportRoot)
        let receipt = try storage.loadReceipt(family: family)
        let planner = InstallPlanner(manifest: manifest, receipt: receipt, helperPath: helperPath)
        let plan = try planner.plan(configRoot: configRoot, appSupportRoot: appSupportRoot)
        let statuses = try catalog.targetStatuses(
            for: family,
            discovery: discovery ?? ProductDiscovery(homeRoot: configRoot)
        )

        var warnings: [String] = []
        if manifest.requiresRestart {
            warnings.append("Restart \(manifest.displayName) after installing so it reloads its configuration.")
        }
        if manifest.requiresHookTrust {
            warnings.append("\(manifest.displayName) requires you to trust the installed hook before events arrive.")
        }
        for status in statuses where status.verificationLevel == .unverified {
            warnings.append(
                "Target \(status.id) is unverified; installation does not raise its verification level."
            )
        }

        var conflicts = plan.allConflicts
        for pending in (try? storage.loadJournals()) ?? [] where pending.stage.isUnresolved {
            conflicts.append(
                "operation \(pending.operationId) for \(pending.family) must be recovered before changing this package"
            )
        }

        let entries = plan.steps.flatMap { step in
            step.entries.map { entry in
                PreviewEntry(
                    target: entry.entry.target,
                    path: entry.path,
                    format: entry.entry.format,
                    kind: entry.entry.kind,
                    marker: entry.marker,
                    action: entry.action
                )
            }
        }

        return InstallPreview(
            family: manifest.family,
            displayName: manifest.displayName,
            packageVersion: manifest.packageVersion,
            requiresRestart: manifest.requiresRestart,
            requiresHookTrust: manifest.requiresHookTrust,
            notes: manifest.notes,
            configRoot: configRoot.path,
            appSupportRoot: appSupportRoot.path,
            helperPath: helperPath,
            activationGeneration: plan.generation,
            previousGeneration: plan.previousGeneration,
            resolvedTargets: Array(Set(plan.steps.map(\.target))).sorted(),
            targets: statuses,
            entries: entries,
            paths: plan.affectedPaths,
            warnings: warnings,
            conflicts: conflicts,
            inputDigest: Self.digest(plan: plan, states: plan.initialStates),
            plan: plan
        )
    }

    // MARK: Apply

    /// Installs a previewed package. Refuses a stale preview or a conflicting
    /// plan before any mutation.
    func apply(_ preview: InstallPreview, now: Date = Date()) throws -> InstallReceipt {
        let plan = preview.plan
        let storage = InstallerStorage(root: URL(fileURLWithPath: plan.appSupportRoot, isDirectory: true))

        try recoverPending(appSupportRoot: storage.root)
        try refuseUnresolvedOperations(in: storage)

        guard preview.conflicts.isEmpty, plan.allConflicts.isEmpty else {
            throw InstallerError.conflicts(plan.allConflicts.isEmpty ? preview.conflicts : plan.allConflicts)
        }

        let currentStates = try states(for: plan.affectedPaths)
        guard currentStates == plan.initialStates,
              Self.digest(plan: plan, states: currentStates) == preview.inputDigest else {
            throw InstallerError.stalePreview("configuration changed since the preview was produced")
        }
        let existingReceipt = try storage.loadReceipt(family: plan.family)
        guard existingReceipt?.activationGeneration == plan.previousGeneration else {
            throw InstallerError.stalePreview("the installed receipt changed since the preview was produced")
        }

        try storage.prepare()

        // The complete receipt is known before the first mutation, so a crash
        // at any point can be completed forward without guessing ownership.
        var createdPaths: [String] = []
        let receipt = InstallReceipt(
            schema: InstallReceipt.currentSchema,
            family: plan.family,
            packageVersion: plan.packageVersion,
            activationGeneration: plan.generation,
            installedAt: now,
            stage: .committed,
            entries: plan.steps.flatMap { step in
                step.entries.map { entry -> InstalledEntry in
                    var value = entry.entry
                    let fileExisted = plan.initialStates[entry.path]?.exists ?? false
                    let previouslyCreated = existingReceipt?.entries.contains {
                        $0.path == entry.path && $0.marker == entry.marker && $0.createdFile
                    } ?? false
                    value.createdFile = !fileExisted || previouslyCreated
                    return value
                }
            },
            previousGeneration: plan.previousGeneration,
            createdDirectories: []
        )

        let mutationCount = plan.steps.filter { step in
            step.entries.contains { $0.action.needsWrite }
        }.count + plan.obsolete.filter { entry in
            guard let state = plan.initialStates[entry.path] else { return false }
            return state.exists && !state.isDirectory
        }.count

        let operationId = Self.newOperationId(at: now)
        var journal = OperationJournal(
            schema: OperationJournal.currentSchema,
            operationId: operationId,
            family: plan.family,
            action: .install,
            stage: .prepared,
            startedAt: now,
            steps: [],
            createdPaths: [],
            expectedMutations: mutationCount,
            receipt: receipt
        )
        try storage.writeJournal(journal)
        try faults?(.journalWritten)

        journal.stage = .applying
        try storage.writeJournal(journal)

        // 1. Immutable copy of the bundled package.
        let packageDirectory = URL(fileURLWithPath: plan.packageDirectory, isDirectory: true)
        let packageHashBefore = try treeHash(packageDirectory)
        let packageHashAfter = try treeHash(URL(fileURLWithPath: plan.manifestDirectory, isDirectory: true))
        if packageHashBefore != packageHashAfter {
            var scratch: [String] = []
            let backup = storage.backupPath(operationId: operationId, index: 0)
            try ConfigEditor.ensureParent(of: backup, created: &scratch)
            if packageHashBefore != nil {
                try moveItem(from: packageDirectory, to: backup)
            }
            try copyPackage(
                from: URL(fileURLWithPath: plan.manifestDirectory, isDirectory: true),
                to: packageDirectory
            )
            if packageHashBefore == nil { createdPaths.append(packageDirectory.path) }
            journal.steps.append(
                JournalStep(
                    operation: "package",
                    target: plan.family,
                    path: packageDirectory.path,
                    beforeHash: packageHashBefore,
                    afterHash: try treeHash(packageDirectory),
                    backupPath: packageHashBefore == nil ? nil : backup.path,
                    applied: true,
                    created: packageHashBefore == nil,
                    undo: nil
                )
            )
            journal.createdPaths = createdPaths
            journal.receipt?.createdDirectories = createdPaths
            try storage.writeJournal(journal)
        }

        // 2. Declarative configuration edits.
        var faultIndex = 0
        for planned in plan.steps where planned.entries.contains(where: { $0.action.needsWrite }) {
            try faults?(.beforeStep(faultIndex))
            try applyConfigMutation(planned, journal: &journal, storage: storage, created: &createdPaths)
            journal.createdPaths = createdPaths
            journal.receipt?.createdDirectories = createdPaths
            try storage.writeJournal(journal)
            try faults?(.afterStep(faultIndex))
            faultIndex += 1
        }

        // 3. Entries this package no longer declares.
        for entry in plan.obsolete {
            let url = URL(fileURLWithPath: entry.path)
            let before = try ConfigEditor.state(of: url)
            guard before.exists, !before.isDirectory else { continue }
            try applyRemovalStep(
                entry,
                operation: "obsolete",
                journal: &journal,
                storage: storage
            )
            journal.receipt?.createdDirectories = createdPaths
            try faults?(.afterStep(faultIndex))
            faultIndex += 1
        }

        // 4. Commit.
        journal.receipt?.createdDirectories = createdPaths
        journal.stage = .committed
        try storage.writeJournal(journal)
        try faults?(.beforeReceipt)
        try storage.saveReceipt(journal.receipt ?? receipt)
        try faults?(.afterReceipt)
        try storage.deleteJournal(operationId: operationId)
        return journal.receipt ?? receipt
    }

    // MARK: Removal

    /// Removes exactly the entries a receipt records. Foreign entries and
    /// foreign files survive.
    func remove(
        family: String,
        appSupportRoot: URL,
        now: Date = Date()
    ) throws -> RemovalReport {
        let storage = InstallerStorage(root: appSupportRoot)
        try recoverPending(appSupportRoot: appSupportRoot)
        try refuseUnresolvedOperations(in: storage)

        guard let receipt = try storage.loadReceipt(family: family) else {
            throw InstallerError.noReceipt(family: family)
        }

        var conflicts: [String] = []
        var present: [InstalledEntry] = []
        for entry in receipt.entries {
            let file = try loadFile(entry.path)
            guard let current = try InstallPlanner.currentEntryHash(entry, in: file) else { continue }
            if current != entry.expectedHash {
                conflicts.append(
                    "\(entry.path): entry \"\(entry.marker)\" was edited after installation and is preserved"
                )
                continue
            }
            present.append(entry)
        }
        guard conflicts.isEmpty else { throw InstallerError.conflicts(conflicts) }

        try storage.prepare()
        let operationId = Self.newOperationId(at: now)
        var journal = OperationJournal(
            schema: OperationJournal.currentSchema,
            operationId: operationId,
            family: family,
            action: .remove,
            stage: .prepared,
            startedAt: now,
            steps: [],
            createdPaths: [],
            expectedMutations: present.count,
            receipt: nil
        )
        try storage.writeJournal(journal)
        try faults?(.journalWritten)
        journal.stage = .applying
        try storage.writeJournal(journal)

        // The package directory was copied by the install and is app-owned.
        let packageDirectory = storage.packagePath(family: family)
        if let packageHash = try treeHash(packageDirectory) {
            var scratch: [String] = []
            let backup = storage.backupPath(operationId: operationId, index: 0)
            try ConfigEditor.ensureParent(of: backup, created: &scratch)
            journal.steps.append(
                JournalStep(
                    operation: "package",
                    target: family,
                    path: packageDirectory.path,
                    beforeHash: packageHash,
                    afterHash: nil,
                    backupPath: backup.path,
                    applied: false,
                    created: false,
                    undo: nil
                )
            )
            try storage.writeJournal(journal)
            try moveItem(from: packageDirectory, to: backup)
            try finishLastStep(&journal, storage: storage)
        }

        var removedPaths: [String] = []
        var preservedPaths: [String] = []
        for (offset, entry) in present.enumerated() {
            try faults?(.beforeStep(offset))
            let url = URL(fileURLWithPath: entry.path)
            let before = try ConfigEditor.state(of: url)
            guard before.exists, !before.isDirectory else { continue }
            try applyRemovalStep(entry, operation: "config", journal: &journal, storage: storage)
            try faults?(.afterStep(offset))

            let after = try ConfigEditor.state(of: url)
            removedPaths.append(entry.path)
            if after.exists { preservedPaths.append(entry.path) }
        }

        for entry in receipt.entries where entry.kind != .hookConfig && !entry.createdFile {
            preservedPaths.append(entry.path)
        }

        journal.stage = .committed
        try storage.writeJournal(journal)
        try faults?(.beforeReceipt)
        try storage.deleteReceipt(family: family)
        try storage.deleteJournal(operationId: operationId)
        try removeCreatedDirectories(receipt.createdDirectories)

        return RemovalReport(
            family: family,
            removedPaths: Array(Set(removedPaths)).sorted(),
            preservedPaths: Array(Set(preservedPaths)).sorted(),
            warnings: []
        )
    }

    // MARK: Recovery

    /// Runs before any new operation. Completes a finished mutation set,
    /// otherwise rolls back to the prepared state. Never overwrites a file the
    /// user edited after the operation touched it.
    @discardableResult
    func recoverPending(appSupportRoot: URL) throws -> [RecoveryReport] {
        let storage = InstallerStorage(root: appSupportRoot)
        guard storage.exists() else { return [] }
        var reports: [RecoveryReport] = []
        for journal in try storage.loadJournals() {
            reports.append(try recover(journal, storage: storage))
        }
        return reports
    }

    private func recover(_ journal: OperationJournal, storage: InstallerStorage) throws -> RecoveryReport {
        var journal = journal
        if journal.stage == .committed {
            try completeForward(journal, storage: storage)
            try storage.deleteJournal(operationId: journal.operationId)
            return RecoveryReport(
                operationId: journal.operationId,
                family: journal.family,
                action: journal.action,
                outcome: .forwardCommitted,
                conflicts: []
            )
        }

        // Only the last step that touched a file describes its content: an
        // earlier step in the same file was superseded by a later one.
        var lastByPath: [String: JournalStep] = [:]
        for step in journal.steps where step.applied {
            lastByPath[step.path] = step
        }
        let recordedMutations = journal.steps.filter {
            $0.operation == "config" || $0.operation == "obsolete"
        }.count
        let allApplied = journal.steps.allSatisfy { $0.applied }
        let contentsIntact = lastByPath.allSatisfy { path, step in
            (try? currentHash(ofPath: path)) == step.afterHash
        }
        let finished = allApplied
            && contentsIntact
            && recordedMutations == journal.expectedMutations
            && (journal.action == .remove || !(journal.receipt?.entries.isEmpty ?? true))
        if finished {
            try completeForward(journal, storage: storage)
            try storage.deleteJournal(operationId: journal.operationId)
            return RecoveryReport(
                operationId: journal.operationId,
                family: journal.family,
                action: journal.action,
                outcome: .forwardCommitted,
                conflicts: []
            )
        }

        // A file whose bytes are not what the operation left behind was edited
        // afterwards; rollback refuses to replace it.
        var conflicts: [String] = []
        for (path, step) in lastByPath.sorted(by: { $0.key < $1.key }) {
            if (try? currentHash(ofPath: path)) != step.afterHash {
                conflicts.append(
                    "\(path): current content differs from the operation's result; it is preserved"
                )
            }
        }
        guard conflicts.isEmpty else {
            journal.stage = .recoveryRequired
            try storage.writeJournal(journal)
            return RecoveryReport(
                operationId: journal.operationId,
                family: journal.family,
                action: journal.action,
                outcome: .recoveryRequired,
                conflicts: conflicts
            )
        }

        for step in journal.steps.reversed() {
            try rollBack(step)
        }
        journal.stage = .prepared
        try storage.writeJournal(journal)
        let stepPaths = Set(journal.steps.map(\.path))
        try removeCreatedDirectories(journal.createdPaths.filter { !stepPaths.contains($0) })
        try storage.deleteJournal(operationId: journal.operationId)
        return RecoveryReport(
            operationId: journal.operationId,
            family: journal.family,
            action: journal.action,
            outcome: .rolledBack,
            conflicts: []
        )
    }

    private func completeForward(_ journal: OperationJournal, storage: InstallerStorage) throws {
        switch journal.action {
        case .install:
            if let receipt = journal.receipt, !receipt.entries.isEmpty {
                try storage.saveReceipt(receipt)
            }
        case .remove:
            try storage.deleteReceipt(family: journal.family)
            try removeCreatedDirectories(journal.createdPaths)
        }
    }

    // MARK: Mutation helpers

    private func applyConfigMutation(
        _ planned: PlannedStep,
        journal: inout OperationJournal,
        storage: InstallerStorage,
        created: inout [String]
    ) throws {
        let url = URL(fileURLWithPath: planned.path)
        let before = try ConfigEditor.state(of: url)
        let file = InstallPlanner.LoadedFile(
            state: before,
            data: before.exists && !before.isDirectory ? try ConfigEditor.read(url) : nil
        )
        let undo = insertionUndo(for: planned, file: file)

        // Register the step before touching the file so a crash mid-write is
        // discoverable and reversible.
        journal.steps.append(
            JournalStep(
                operation: "config",
                target: planned.target,
                path: planned.path,
                beforeHash: before.sha256,
                afterHash: nil,
                backupPath: nil,
                applied: false,
                created: !before.exists,
                undo: undo
            )
        )
        try storage.writeJournal(journal)

        try performMutation(planned, created: &created)
        try finishLastStep(&journal, storage: storage)
    }

    /// Removes one receipt entry and records the app-owned content needed to
    /// put it back.
    private func applyRemovalStep(
        _ entry: InstalledEntry,
        operation: String,
        journal: inout OperationJournal,
        storage: InstallerStorage
    ) throws {
        let url = URL(fileURLWithPath: entry.path)
        let before = try ConfigEditor.state(of: url)
        let file = InstallPlanner.LoadedFile(
            state: before,
            data: before.exists && !before.isDirectory ? try ConfigEditor.read(url) : nil
        )
        let undo = try removalUndo(for: entry, file: file)
        journal.steps.append(
            JournalStep(
                operation: operation,
                target: entry.target,
                path: entry.path,
                beforeHash: before.sha256,
                afterHash: nil,
                backupPath: nil,
                applied: false,
                created: false,
                undo: undo
            )
        )
        try storage.writeJournal(journal)
        try removeOwnedEntryContent(entry)
        try finishLastStep(&journal, storage: storage)
    }

    /// Records the post-mutation hash of the last registered step.
    private func finishLastStep(_ journal: inout OperationJournal, storage: InstallerStorage) throws {
        guard let index = journal.steps.indices.last else { return }
        let path = journal.steps[index].path
        journal.steps[index].afterHash = try currentHash(ofPath: path)
        journal.steps[index].applied = true
        try storage.writeJournal(journal)
    }

    private func insertionUndo(for planned: PlannedStep, file: InstallPlanner.LoadedFile) -> JournalUndo {
        if planned.kind.isFileCopy {
            if let data = file.data {
                return JournalUndo(
                    kind: .restoreFile,
                    keyPath: nil,
                    prefix: nil,
                    markers: nil,
                    texts: [String(decoding: data, as: UTF8.self)]
                )
            }
            return JournalUndo(kind: .deleteFile, keyPath: nil, prefix: nil, markers: nil, texts: nil)
        }
        switch planned.format {
        case .json:
            return JournalUndo(
                kind: .removeJSONEntries,
                keyPath: planned.entries.first?.entry.keyPath,
                prefix: nil,
                markers: planned.entries.map(\.marker),
                texts: nil
            )
        case .toml, .yaml, .text:
            return JournalUndo(
                kind: .removeBlocks,
                keyPath: nil,
                prefix: planned.format.blockCommentPrefix,
                markers: planned.entries.map(\.marker),
                texts: nil
            )
        case .directory:
            return JournalUndo(kind: .deleteFile, keyPath: nil, prefix: nil, markers: nil, texts: nil)
        }
    }

    /// The undo payload contains only bytes this app rendered: the removed
    /// marker value, the removed block, or the app-owned copied file.
    private func removalUndo(
        for entry: InstalledEntry,
        file: InstallPlanner.LoadedFile
    ) throws -> JournalUndo? {
        guard let data = file.data else { return nil }
        switch entry.kind {
        case .hookConfig:
            switch entry.format {
            case .json:
                guard let keyPath = entry.keyPath else { return nil }
                let root: JSONValue
                do {
                    root = try JSONValue.parse(data)
                } catch {
                    throw InstallerError.malformedJSON(path: entry.path, detail: String(describing: error))
                }
                guard let value = try JSONMutation.value(in: root, keyPath: keyPath, marker: entry.marker) else {
                    return nil
                }
                return JournalUndo(
                    kind: .restoreJSONEntries,
                    keyPath: keyPath,
                    prefix: nil,
                    markers: [entry.marker],
                    texts: [String(decoding: value.canonicalData(), as: UTF8.self)]
                )
            case .toml, .yaml, .text:
                let text = String(decoding: data, as: UTF8.self)
                guard case .found(let range, _) = MarkerBlock.locate(
                    in: text,
                    marker: entry.marker,
                    prefix: entry.format.blockCommentPrefix
                ) else {
                    return nil
                }
                return JournalUndo(
                    kind: .restoreBlocks,
                    keyPath: nil,
                    prefix: entry.format.blockCommentPrefix,
                    markers: [entry.marker],
                    texts: [String(text[range])]
                )
            case .directory:
                return nil
            }
        case .pluginFile, .extensionFile, .commandWrapper:
            return JournalUndo(
                kind: .restoreFile,
                keyPath: nil,
                prefix: nil,
                markers: nil,
                texts: [String(decoding: data, as: UTF8.self)]
            )
        }
    }

    private func performMutation(_ planned: PlannedStep, created: inout [String]) throws {
        let url = URL(fileURLWithPath: planned.path)
        if planned.kind.isFileCopy {
            guard let entry = planned.entries.first(where: { $0.action.needsWrite }),
                  case .copyFile(let contents) = entry.mutation else { return }
            try ConfigEditor.ensureParent(of: url, created: &created)
            try ConfigEditor.writeAtomically(contents, to: url)
            return
        }
        switch planned.format {
        case .json:
            let existing = try ConfigEditor.readIfPresent(url) ?? Data("{}".utf8)
            var root: JSONValue
            do {
                root = try JSONValue.parse(existing)
            } catch {
                throw InstallerError.malformedJSON(path: planned.path, detail: String(describing: error))
            }
            var changed = false
            for entry in planned.entries where entry.action.needsWrite {
                guard case .jsonEntry(let keyPath, let marker, let value) = entry.mutation else {
                    throw InstallerError.invalidPlan("entry \(entry.marker) has no JSON mutation")
                }
                root = try JSONMutation.inserting(value, into: root, keyPath: keyPath, marker: marker)
                changed = true
            }
            if changed {
                try ConfigEditor.ensureParent(of: url, created: &created)
                try ConfigEditor.writeAtomically(root.data(pretty: true), to: url)
            }
        case .toml, .yaml, .text:
            var text = (try ConfigEditor.readIfPresent(url)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            var changed = false
            for entry in planned.entries where entry.action.needsWrite {
                guard case .block(let marker, let blockText) = entry.mutation else {
                    throw InstallerError.invalidPlan("entry \(entry.marker) has no block mutation")
                }
                let applied = try MarkerBlock.applying(
                    blockText,
                    to: text,
                    marker: marker,
                    prefix: planned.format.blockCommentPrefix
                )
                text = applied.text
                changed = changed || applied.changed
            }
            if changed {
                try ConfigEditor.ensureParent(of: url, created: &created)
                try ConfigEditor.writeAtomically(Data(text.utf8), to: url)
            }
        case .directory:
            return
        }
    }

    /// Removes one owned entry from its file, preserving everything else.
    private func removeOwnedEntryContent(_ entry: InstalledEntry) throws {
        let url = URL(fileURLWithPath: entry.path)
        let file = try loadFile(entry.path)
        guard let data = file.data else { return }
        switch entry.kind {
        case .hookConfig:
            switch entry.format {
            case .json:
                guard let keyPath = entry.keyPath else {
                    throw InstallerError.invalidPlan("entry \(entry.marker) has no keyPath")
                }
                var root: JSONValue
                do {
                    root = try JSONValue.parse(data)
                } catch {
                    throw InstallerError.malformedJSON(path: entry.path, detail: String(describing: error))
                }
                root = try JSONMutation.removing(from: root, keyPath: keyPath, marker: entry.marker)
                root = pruneEmptyContainers(root, keyPath: keyPath)
                if entry.createdFile, root == .object([:]) {
                    try ConfigEditor.removeIfPresent(url)
                } else {
                    try ConfigEditor.writeAtomically(root.data(pretty: true), to: url)
                }
            case .toml, .yaml, .text:
                let text = String(decoding: data, as: UTF8.self)
                let removed = try MarkerBlock.removing(
                    from: text,
                    marker: entry.marker,
                    prefix: entry.format.blockCommentPrefix
                )
                if entry.createdFile, removed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try ConfigEditor.removeIfPresent(url)
                } else if removed.removed {
                    try ConfigEditor.writeAtomically(Data(removed.text.utf8), to: url)
                }
            case .directory:
                return
            }
        case .pluginFile, .extensionFile, .commandWrapper:
            if entry.createdFile {
                try ConfigEditor.removeIfPresent(url)
            }
        }
    }

    /// Removes containers the marker left empty, deepest first. Foreign keys
    /// inside an app-owned container are preserved.
    private func pruneEmptyContainers(_ node: JSONValue, keyPath: [String]) -> JSONValue {
        guard let head = keyPath.first, let object = node.objectValue, let child = object[head] else {
            return node
        }
        var updated = object
        let pruned = pruneEmptyContainers(child, keyPath: Array(keyPath.dropFirst()))
        if keyPath.count == 1, case .object(let dictionary) = pruned, dictionary.isEmpty {
            updated.removeValue(forKey: head)
        } else {
            updated[head] = pruned
        }
        return .object(updated)
    }

    // MARK: Rollback

    private func rollBack(_ step: JournalStep) throws {
        let url = URL(fileURLWithPath: step.path)
        if step.operation == "package" {
            if let backupPath = step.backupPath, FileManager.default.fileExists(atPath: backupPath) {
                try? FileManager.default.removeItem(at: url)
                var scratch: [String] = []
                try ConfigEditor.ensureParent(of: url, created: &scratch)
                try moveItem(from: URL(fileURLWithPath: backupPath), to: url)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
            return
        }
        guard let undo = step.undo else {
            if step.created { try? FileManager.default.removeItem(at: url) }
            return
        }
        try applyUndo(undo, path: step.path, created: step.created)
    }

    /// Undo instructions are idempotent, so a step registered just before an
    /// interruption is safe to reverse whether or not its write landed.
    private func applyUndo(_ undo: JournalUndo, path: String, created: Bool) throws {
        let url = URL(fileURLWithPath: path)
        let file = try loadFile(path)
        var scratch: [String] = []

        switch undo.kind {
        case .deleteFile:
            try ConfigEditor.removeIfPresent(url)

        case .restoreFile:
            guard let text = undo.texts?.first else { return }
            if file.data.map({ String(decoding: $0, as: UTF8.self) }) == text { return }
            try ConfigEditor.ensureParent(of: url, created: &scratch)
            try ConfigEditor.writeAtomically(Data(text.utf8), to: url)

        case .removeJSONEntries:
            guard let data = file.data, let keyPath = undo.keyPath else { return }
            var root: JSONValue
            do {
                root = try JSONValue.parse(data)
            } catch {
                throw InstallerError.malformedJSON(path: path, detail: String(describing: error))
            }
            var changed = false
            for marker in undo.markers ?? [] {
                guard (try? JSONMutation.value(in: root, keyPath: keyPath, marker: marker)) != nil else {
                    continue
                }
                root = try JSONMutation.removing(from: root, keyPath: keyPath, marker: marker)
                root = pruneEmptyContainers(root, keyPath: keyPath)
                changed = true
            }
            guard changed else { return }
            if created, root == .object([:]) {
                try ConfigEditor.removeIfPresent(url)
            } else {
                try ConfigEditor.writeAtomically(root.data(pretty: true), to: url)
            }

        case .restoreJSONEntries:
            guard let keyPath = undo.keyPath else { return }
            var root: JSONValue = .object([:])
            if let data = file.data {
                do {
                    root = try JSONValue.parse(data)
                } catch {
                    throw InstallerError.malformedJSON(path: path, detail: String(describing: error))
                }
            }
            for (index, marker) in (undo.markers ?? []).enumerated() {
                guard index < (undo.texts ?? []).count,
                      let value = try? JSONValue.parse(Data((undo.texts ?? [])[index].utf8)) else {
                    continue
                }
                root = try JSONMutation.inserting(value, into: root, keyPath: keyPath, marker: marker)
            }
            try ConfigEditor.ensureParent(of: url, created: &scratch)
            try ConfigEditor.writeAtomically(root.data(pretty: true), to: url)

        case .removeBlocks:
            guard let data = file.data else { return }
            var text = String(decoding: data, as: UTF8.self)
            var changed = false
            for marker in undo.markers ?? [] {
                let removed = try MarkerBlock.removing(
                    from: text,
                    marker: marker,
                    prefix: undo.prefix ?? "#"
                )
                text = removed.text
                changed = changed || removed.removed
            }
            guard changed else { return }
            if created, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try ConfigEditor.removeIfPresent(url)
            } else {
                try ConfigEditor.writeAtomically(Data(text.utf8), to: url)
            }

        case .restoreBlocks:
            var text = file.data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            for (index, marker) in (undo.markers ?? []).enumerated() {
                let texts = undo.texts ?? []
                guard index < texts.count else { continue }
                let applied = try MarkerBlock.applying(
                    texts[index],
                    to: text,
                    marker: marker,
                    prefix: undo.prefix ?? "#"
                )
                text = applied.text
            }
            try ConfigEditor.ensureParent(of: url, created: &scratch)
            try ConfigEditor.writeAtomically(Data(text.utf8), to: url)
        }
    }

    // MARK: Reading helpers

    private func refuseUnresolvedOperations(in storage: InstallerStorage) throws {
        for journal in try storage.loadJournals() where journal.stage.isUnresolved {
            throw InstallerError.blockedByRecovery(operationId: journal.operationId)
        }
    }

    private func states(for paths: [String]) throws -> [String: FileState] {
        var result: [String: FileState] = [:]
        for path in paths {
            result[path] = try ConfigEditor.state(of: URL(fileURLWithPath: path))
        }
        return result
    }

    private func loadFile(_ path: String) throws -> InstallPlanner.LoadedFile {
        let url = URL(fileURLWithPath: path)
        let state = try ConfigEditor.state(of: url)
        return InstallPlanner.LoadedFile(
            state: state,
            data: state.exists && !state.isDirectory ? try ConfigEditor.read(url) : nil
        )
    }

    private func currentHash(of step: JournalStep) throws -> String? {
        try currentHash(ofPath: step.path)
    }

    private func currentHash(ofPath path: String) throws -> String? {
        let url = URL(fileURLWithPath: path)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            throw InstallerError.symlinked(path: path)
        case S_IFDIR:
            return try treeHash(url)
        default:
            return try ConfigEditor.state(of: url).sha256
        }
    }

    // MARK: File helpers

    private func removeCreatedDirectories(_ paths: [String]) throws {
        for path in paths.sorted(by: { $0.count > $1.count }) {
            let url = URL(fileURLWithPath: path)
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
                continue
            }
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            guard contents.isEmpty else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func moveItem(from source: URL, to destination: URL) throws {
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            throw InstallerError.writeFailed(path: destination.path, detail: error.localizedDescription)
        }
    }

    private func copyPackage(from source: URL, to destination: URL) throws {
        do {
            try ConfigEditor.copyDirectoryContents(from: source, to: destination)
        } catch let error as InstallerError {
            throw error
        } catch {
            throw InstallerError.writeFailed(path: destination.path, detail: error.localizedDescription)
        }
    }

    /// Hash of a file or a directory tree. Directories hash their sorted
    /// relative names and file contents.
    private func treeHash(_ url: URL) throws -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let type = info.st_mode & S_IFMT
        if type == S_IFLNK { throw InstallerError.symlinked(path: url.path) }
        if type == S_IFREG { return try ConfigEditor.state(of: url).sha256 }
        guard type == S_IFDIR else { return nil }
        var parts: [String] = []
        try collectTreeHashes(url, prefix: "", into: &parts)
        return Digests.sha256(parts.joined(separator: "\n"))
    }

    private func collectTreeHashes(_ directory: URL, prefix: String, into parts: inout [String]) throws {
        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        } catch {
            throw InstallerError.writeFailed(path: directory.path, detail: error.localizedDescription)
        }
        for entry in entries {
            let child = directory.appendingPathComponent(entry)
            let relative = prefix.isEmpty ? entry : "\(prefix)/\(entry)"
            var info = stat()
            guard lstat(child.path, &info) == 0 else { continue }
            let type = info.st_mode & S_IFMT
            if type == S_IFLNK { throw InstallerError.symlinked(path: child.path) }
            if type == S_IFDIR {
                parts.append("d:\(relative)")
                try collectTreeHashes(child, prefix: relative, into: &parts)
            } else if type == S_IFREG {
                parts.append("f:\(relative):\(Digests.sha256(try ConfigEditor.read(child)))")
            }
        }
    }

    /// Random identifier with a monotonic prefix; the journal file name is
    /// derived from it, so a name cannot be predicted or reused.
    static func newOperationId(at date: Date) -> String {
        let micros = UInt64(max(0, (date.timeIntervalSince1970 * 1_000_000).rounded(.down)))
        var bytes = [UInt8](repeating: 0, count: 8)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        let random = bytes.map { String(format: "%02x", $0) }.joined()
        return String(format: "%020llu", micros) + "-" + random
    }

    /// Digest of every input a preview depends on.
    static func digest(plan: InstallPlan, states: [String: FileState]) -> String {
        var text = "awake-lite/install-preview/1\n"
        text += "family=\(plan.family)\n"
        text += "packageVersion=\(plan.packageVersion)\n"
        text += "generation=\(plan.generation)\n"
        text += "previous=\(plan.previousGeneration.map(String.init) ?? "-")\n"
        text += "helper=\(plan.helperPath)\n"
        text += "configRoot=\(plan.configRoot)\n"
        text += "appSupport=\(plan.appSupportRoot)\n"
        for step in plan.steps {
            for entry in step.entries {
                text += "entry=\(entry.entry.kind.rawValue)|\(entry.entry.format.rawValue)"
                text += "|\(entry.entry.marker)|\(entry.path)|\(entry.entry.expectedHash)\n"
            }
        }
        for entry in plan.obsolete.sorted(by: { $0.marker < $1.marker }) {
            text += "obsolete=\(entry.marker)|\(entry.path)|\(entry.expectedHash)\n"
        }
        for path in plan.affectedPaths.sorted() {
            let state = states[path] ?? .missing
            text += "state=\(path)|\(state.exists)|\(state.isDirectory)|\(state.sha256 ?? "-")\n"
        }
        return Digests.sha256(text)
    }
}
