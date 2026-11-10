import Foundation

// MARK: - Lifecycle vocabulary

enum InstallAction: String, Codable, Equatable {
    case install
    case remove
}

enum InstallStage: String, Codable, Equatable {
    case prepared
    case applying
    case committed
    case recoveryRequired

    var isUnresolved: Bool {
        switch self {
        case .prepared, .applying, .recoveryRequired: return true
        case .committed: return false
        }
    }
}

/// One owned entry after installation. `expectedHash` is what removal and
/// rollback compare against; a different value means the user edited it.
///
/// `kind`, `keyPath`, and `createdFile` extend the lean receipt contract: the
/// installer needs them to undo exactly one entry and to know whether it may
/// delete a file. None of them carries configuration content.
struct InstalledEntry: Codable, Equatable {
    var target: String
    var path: String
    var format: StepFormat
    var marker: String
    var expectedHash: String
    var kind: StepKind
    var keyPath: [String]?
    var createdFile: Bool
}

/// Schema-1 receipt: ownership and lifecycle metadata only.
struct InstallReceipt: Codable, Equatable {
    static let currentSchema = 1

    var schema: Int
    var family: String
    var packageVersion: String
    var activationGeneration: UInt64
    var installedAt: Date
    var stage: InstallStage
    var entries: [InstalledEntry]
    var previousGeneration: UInt64?
    /// Directories the install created; removal deletes only these.
    var createdDirectories: [String]
}

// MARK: - Plan

enum PlannedMutation: Equatable {
    /// Insert `value` at `keyPath[marker]`, preserving every other key.
    case jsonEntry(keyPath: [String], marker: String, value: JSONValue)
    /// Append or replace one marker-delimited block.
    case block(marker: String, blockText: String)
    /// Copy one rendered asset to a wholly app-owned destination.
    case copyFile(contents: Data)
}

enum PreviewAction: String, Equatable {
    case create
    case update
    case unchanged
    case conflict

    var needsWrite: Bool {
        self == .create || self == .update
    }
}

struct PlannedEntry: Equatable {
    /// Receipt entry for this owned entry; `createdFile` is filled at apply.
    var entry: InstalledEntry
    var assetID: String
    var action: PreviewAction
    var mutation: PlannedMutation

    var marker: String { entry.marker }
    var path: String { entry.path }
}

struct PlannedStep: Equatable {
    var index: Int
    var target: String
    var path: String
    var format: StepFormat
    var kind: StepKind
    var entries: [PlannedEntry]
    var conflicts: [String]
}

/// Everything `apply` needs. Produced by `preview`; never edited afterwards.
struct InstallPlan: Equatable {
    var family: String
    var packageVersion: String
    var generation: UInt64
    var previousGeneration: UInt64?
    var helperPath: String
    /// Injected home root; `~` and `$HOME` selectors resolve here.
    var configRoot: String
    var appSupportRoot: String
    var packageDirectory: String
    var manifestDirectory: String
    var steps: [PlannedStep]
    /// Previously installed entries this package no longer declares.
    var obsolete: [InstalledEntry]
    /// File state every affected path had at preview time.
    var initialStates: [String: FileState]
    /// Plan-level conflicts, such as an obsolete entry someone edited.
    var conflicts: [String]

    /// Every configuration path this operation would read or write.
    var affectedPaths: [String] {
        Array(Set(steps.map(\.path)).union(obsolete.map(\.path))).sorted()
    }

    var stepConflicts: [String] {
        steps.flatMap(\.conflicts)
    }

    var allConflicts: [String] {
        Array(Set(stepConflicts + conflicts)).sorted()
    }
}

// MARK: - Preview

struct PreviewEntry: Equatable {
    var target: String
    var path: String
    var format: StepFormat
    var kind: StepKind
    var marker: String
    var action: PreviewAction
}

/// What the confirmation sheet shows and what `apply` validates against.
struct InstallPreview: Equatable {
    var family: String
    var displayName: String
    var packageVersion: String
    var requiresRestart: Bool
    var requiresHookTrust: Bool
    var notes: [String]
    var configRoot: String
    var appSupportRoot: String
    var helperPath: String
    var activationGeneration: UInt64
    var previousGeneration: UInt64?
    /// Targets this package would configure, exactly as resolved.
    var resolvedTargets: [String]
    /// Declared targets with local availability. Availability never raises a
    /// verification level.
    var targets: [TargetStatus]
    var entries: [PreviewEntry]
    var paths: [String]
    var warnings: [String]
    var conflicts: [String]
    /// Digest of every input: plan shape, receipt generation, file bytes.
    var inputDigest: String
    var plan: InstallPlan

    var canApply: Bool { conflicts.isEmpty }
}

// MARK: - Planner

/// Builds a plan from the catalog, the current receipt, and the current
/// configuration files. Reads only; never mutates.
struct InstallPlanner {
    /// A file as planning saw it plus the in-memory content after earlier
    /// planned steps in the same file.
    struct LoadedFile: Equatable {
        var state: FileState
        var data: Data?
    }

    var manifest: PackageManifest
    var receipt: InstallReceipt?
    var helperPath: String

    /// Supported format per step kind. `hookConfig` edits an existing file at
    /// a key path (JSON) or a marker block (TOML, YAML, text); a directory is
    /// not a hook configuration and is refused rather than guessed.
    static func isSupported(kind: StepKind, format: StepFormat) -> Bool {
        switch kind {
        case .hookConfig:
            return format == .json || format == .toml || format == .yaml || format == .text
        case .pluginFile, .extensionFile, .commandWrapper:
            return true
        }
    }

    func plan(configRoot: URL, appSupportRoot: URL) throws -> InstallPlan {
        let generation = (receipt?.activationGeneration ?? 0) + 1
        let previousGeneration = receipt?.activationGeneration
        var steps: [PlannedStep] = []
        var files: [String: LoadedFile] = [:]

        for (index, step) in manifest.steps.enumerated() {
            guard Self.isSupported(kind: step.kind, format: step.format) else {
                throw InstallerError.unsupportedFormat(
                    step: index,
                    format: step.format,
                    detail: "\(step.kind.rawValue) steps support json, toml, yaml, and text, not \(step.format.rawValue)"
                )
            }
            if step.kind.isFileCopy, step.ownedEntries.count != 1 {
                throw InstallerError.invalidPlan(
                    "step \(index) (\(step.kind.rawValue)) must declare exactly one owned entry"
                )
            }

            let baseRoot: URL
            switch step.configRoot {
            case .home: baseRoot = configRoot
            case .appSupport: baseRoot = appSupportRoot
            }
            let root = step.configRoot.resolve(homeRoot: configRoot, appSupportRoot: appSupportRoot)
            let path = destinationPath(for: step, root: root)

            try ConfigEditor.verifyNoSymlink(root, under: baseRoot)
            try ConfigEditor.verifyNoSymlink(path, under: baseRoot)

            if files[path.path] == nil {
                let state = try ConfigEditor.state(of: path)
                files[path.path] = LoadedFile(
                    state: state,
                    data: state.exists && !state.isDirectory ? try ConfigEditor.read(path) : nil
                )
            }

            if step.kind.isFileCopy {
                steps.append(
                    try planCopyStep(
                        step: step,
                        index: index,
                        path: path,
                        generation: generation,
                        file: &files
                    )
                )
            } else {
                switch step.format {
                case .json:
                    steps.append(
                        try planJSONStep(
                            step: step,
                            index: index,
                            path: path,
                            generation: generation,
                            file: &files
                        )
                    )
                case .toml, .yaml, .text:
                    steps.append(
                        try planBlockStep(
                            step: step,
                            index: index,
                            path: path,
                            generation: generation,
                            file: &files
                        )
                    )
                case .directory:
                    throw InstallerError.unsupportedFormat(
                        step: index,
                        format: step.format,
                        detail: "hookConfig steps cannot use a directory destination"
                    )
                }
            }
        }

        let plannedMarkers = Set(steps.flatMap { $0.entries.map(\.marker) })
        let obsolete = (receipt?.entries ?? []).filter { !plannedMarkers.contains($0.marker) }
        var planConflicts: [String] = []
        for entry in obsolete {
            let file = try loadFile(for: entry.path, files: &files)
            if let current = try Self.currentEntryHash(entry, in: file), current != entry.expectedHash {
                planConflicts.append(
                    "\(entry.path): previously installed entry \"\(entry.marker)\" was edited; it will not be replaced"
                )
            }
        }

        return InstallPlan(
            family: manifest.family,
            packageVersion: manifest.packageVersion,
            generation: generation,
            previousGeneration: previousGeneration,
            helperPath: helperPath,
            configRoot: configRoot.path,
            appSupportRoot: appSupportRoot.path,
            packageDirectory: appSupportRoot
                .appendingPathComponent("packages", isDirectory: true)
                .appendingPathComponent(manifest.family, isDirectory: true)
                .path,
            manifestDirectory: manifest.familyDirectory.path,
            steps: steps,
            obsolete: obsolete,
            initialStates: files.mapValues(\.state),
            conflicts: planConflicts
        )
    }

    /// Copy steps own one destination file. A directory-format step places the
    /// asset inside the app-owned destination directory.
    private func destinationPath(for step: PackageStep, root: URL) -> URL {
        var path = PathRules.appending(step.path, to: root)
        if step.format == .directory,
           let asset = step.ownedEntries.first.flatMap({ manifest.asset(withID: $0.asset) }) {
            path.appendPathComponent(
                asset.source.split(separator: "/").last.map(String.init) ?? "asset"
            )
        }
        return path
    }

    // MARK: File access

    private func loadFile(for path: String, files: inout [String: LoadedFile]) throws -> LoadedFile {
        if let existing = files[path] { return existing }
        let url = URL(fileURLWithPath: path)
        let state = try ConfigEditor.state(of: url)
        let loaded = LoadedFile(
            state: state,
            data: state.exists && !state.isDirectory ? try ConfigEditor.read(url) : nil
        )
        files[path] = loaded
        return loaded
    }

    // MARK: JSON steps

    private func planJSONStep(
        step: PackageStep,
        index: Int,
        path: URL,
        generation: UInt64,
        file: inout [String: LoadedFile]
    ) throws -> PlannedStep {
        guard let keyPath = step.keyPath else {
            throw InstallerError.invalidPlan("step \(index) has no keyPath for a JSON hookConfig step")
        }
        var loaded = try loadFile(for: path.path, files: &file)

        var root: JSONValue = .object([:])
        var conflicts: [String] = []
        if loaded.state.isDirectory {
            conflicts.append("\(path.path): is a directory, not a JSON file")
        } else if let data = loaded.data {
            do {
                root = try JSONValue.parse(data)
            } catch {
                conflicts.append("\(path.path): not valid JSON (\(error)); the file is left untouched")
            }
        }

        var plannedEntries: [PlannedEntry] = []
        for owned in step.ownedEntries {
            let assetValue = try renderedJSONAsset(
                owned.asset,
                marker: owned.marker,
                target: step.target,
                generation: generation
            )
            let renderedHash = Digests.sha256(assetValue.canonicalData())
            let mutation = PlannedMutation.jsonEntry(
                keyPath: keyPath,
                marker: owned.marker,
                value: assetValue
            )
            let entry = InstalledEntry(
                target: step.target,
                path: path.path,
                format: step.format,
                marker: owned.marker,
                expectedHash: renderedHash,
                kind: step.kind,
                keyPath: keyPath,
                createdFile: false
            )

            if !conflicts.isEmpty {
                plannedEntries.append(
                    PlannedEntry(entry: entry, assetID: owned.asset, action: .conflict, mutation: mutation)
                )
                continue
            }

            let existing: JSONValue?
            do {
                existing = try JSONMutation.value(in: root, keyPath: keyPath, marker: owned.marker)
            } catch {
                conflicts.append("\(path.path): \(error)")
                plannedEntries.append(
                    PlannedEntry(entry: entry, assetID: owned.asset, action: .conflict, mutation: mutation)
                )
                continue
            }

            let action: PreviewAction
            if let existing {
                if existing.canonicalData() == assetValue.canonicalData() {
                    action = .unchanged
                } else if ownsExistingValue(path: path.path, marker: owned.marker, value: existing) {
                    action = .update
                } else {
                    action = .conflict
                    conflicts.append(
                        "\(path.path): marker \"\(owned.marker)\" already holds a foreign value; it is preserved"
                    )
                }
            } else {
                action = .create
            }

            if action.needsWrite {
                do {
                    root = try JSONMutation.inserting(
                        assetValue,
                        into: root,
                        keyPath: keyPath,
                        marker: owned.marker
                    )
                    loaded.data = root.data(pretty: true)
                    file[path.path] = loaded
                } catch {
                    conflicts.append("\(path.path): \(error)")
                    plannedEntries.append(
                        PlannedEntry(entry: entry, assetID: owned.asset, action: .conflict, mutation: mutation)
                    )
                    continue
                }
            }
            plannedEntries.append(
                PlannedEntry(entry: entry, assetID: owned.asset, action: action, mutation: mutation)
            )
        }

        return PlannedStep(
            index: index,
            target: step.target,
            path: path.path,
            format: step.format,
            kind: step.kind,
            entries: plannedEntries,
            conflicts: conflicts
        )
    }

    // MARK: Block steps

    private func planBlockStep(
        step: PackageStep,
        index: Int,
        path: URL,
        generation: UInt64,
        file: inout [String: LoadedFile]
    ) throws -> PlannedStep {
        let prefix = step.format.blockCommentPrefix
        var loaded = try loadFile(for: path.path, files: &file)
        var text = loaded.data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        var result: [PlannedEntry] = []
        var conflicts: [String] = []

        if loaded.state.isDirectory {
            conflicts.append("\(path.path): is a directory, not a configuration file")
            for owned in step.ownedEntries {
                let body = try renderedTextAsset(
                    owned.asset,
                    marker: owned.marker,
                    target: step.target,
                    generation: generation
                )
                result.append(
                    PlannedEntry(
                        entry: InstalledEntry(
                            target: step.target,
                            path: path.path,
                            format: step.format,
                            marker: owned.marker,
                            expectedHash: MarkerBlock.bodyHash(trim(body)),
                            kind: step.kind,
                            keyPath: nil,
                            createdFile: false
                        ),
                        assetID: owned.asset,
                        action: .conflict,
                        mutation: .block(
                            marker: owned.marker,
                            blockText: MarkerBlock.text(
                                marker: owned.marker,
                                generation: generation,
                                prefix: prefix,
                                body: body
                            )
                        )
                    )
                )
            }
            return PlannedStep(
                index: index,
                target: step.target,
                path: path.path,
                format: step.format,
                kind: step.kind,
                entries: result,
                conflicts: conflicts
            )
        }

        for owned in step.ownedEntries {
            let body = try renderedTextAsset(
                owned.asset,
                marker: owned.marker,
                target: step.target,
                generation: generation
            )
            let trimmedBody = trim(body)
            let block = MarkerBlock.text(
                marker: owned.marker,
                generation: generation,
                prefix: prefix,
                body: trimmedBody
            )
            let bodyHash = MarkerBlock.bodyHash(trimmedBody)

            let action: PreviewAction
            switch MarkerBlock.locate(in: text, marker: owned.marker, prefix: prefix) {
            case .absent:
                action = .create
            case .found(_, let existingBody):
                if existingBody == trimmedBody {
                    action = .unchanged
                } else if ownsExistingBlock(path: path.path, marker: owned.marker, body: existingBody) {
                    action = .update
                } else {
                    action = .conflict
                    conflicts.append(
                        "\(path.path): block \"\(owned.marker)\" holds foreign content; it is preserved"
                    )
                }
            case .malformed:
                action = .conflict
                conflicts.append("\(path.path): malformed awake-lite block for marker \"\(owned.marker)\"")
            case .duplicate:
                action = .conflict
                conflicts.append("\(path.path): duplicate awake-lite blocks for marker \"\(owned.marker)\"")
            }

            let planned = PlannedEntry(
                entry: InstalledEntry(
                    target: step.target,
                    path: path.path,
                    format: step.format,
                    marker: owned.marker,
                    expectedHash: bodyHash,
                    kind: step.kind,
                    keyPath: nil,
                    createdFile: false
                ),
                assetID: owned.asset,
                action: action,
                mutation: .block(marker: owned.marker, blockText: block)
            )
            result.append(planned)

            if action.needsWrite {
                do {
                    let applied = try MarkerBlock.applying(
                        block,
                        to: text,
                        marker: owned.marker,
                        prefix: prefix
                    )
                    text = applied.text
                    loaded.data = Data(text.utf8)
                    file[path.path] = loaded
                } catch {
                    conflicts.append("\(path.path): \(error)")
                    if let last = result.indices.last { result[last].action = .conflict }
                }
            }
        }

        return PlannedStep(
            index: index,
            target: step.target,
            path: path.path,
            format: step.format,
            kind: step.kind,
            entries: result,
            conflicts: conflicts
        )
    }

    // MARK: Copy steps

    private func planCopyStep(
        step: PackageStep,
        index: Int,
        path: URL,
        generation: UInt64,
        file: inout [String: LoadedFile]
    ) throws -> PlannedStep {
        guard let owned = step.ownedEntries.first else {
            throw InstallerError.invalidPlan("step \(index) has no owned entry")
        }
        let loaded = try loadFile(for: path.path, files: &file)
        let rendered = try renderedTextAsset(
            owned.asset,
            marker: owned.marker,
            target: step.target,
            generation: generation
        )
        let data = Data(rendered.utf8)
        let contentHash = Digests.sha256(data)

        var conflicts: [String] = []
        let action: PreviewAction
        if loaded.state.isDirectory {
            action = .conflict
            conflicts.append("\(path.path): is a directory, not an app-owned file")
        } else if let current = loaded.data {
            if current == data {
                action = .unchanged
            } else if ownsExistingFile(
                path: path.path,
                marker: owned.marker,
                contentHash: Digests.sha256(current)
            ) {
                action = .update
            } else {
                action = .conflict
                conflicts.append("\(path.path): existing content is not owned by this package; it is preserved")
            }
        } else {
            action = .create
        }

        if action.needsWrite {
            file[path.path] = LoadedFile(state: loaded.state, data: data)
        }

        let planned = PlannedEntry(
            entry: InstalledEntry(
                target: step.target,
                path: path.path,
                format: step.format,
                marker: owned.marker,
                expectedHash: contentHash,
                kind: step.kind,
                keyPath: nil,
                createdFile: false
            ),
            assetID: owned.asset,
            action: action,
            mutation: .copyFile(contents: data)
        )
        return PlannedStep(
            index: index,
            target: step.target,
            path: path.path,
            format: step.format,
            kind: step.kind,
            entries: [planned],
            conflicts: conflicts
        )
    }

    // MARK: Ownership

    /// True when the receipt says this exact marker previously held this exact
    /// value, so the plan may replace it with a new generation.
    private func ownsExistingValue(path: String, marker: String, value: JSONValue) -> Bool {
        guard let receipt else { return false }
        let hash = Digests.sha256(value.canonicalData())
        return receipt.entries.contains {
            $0.path == path && $0.marker == marker && $0.expectedHash == hash
        }
    }

    private func ownsExistingBlock(path: String, marker: String, body: String) -> Bool {
        guard let receipt else { return false }
        let hash = MarkerBlock.bodyHash(body)
        return receipt.entries.contains {
            $0.path == path && $0.marker == marker && $0.expectedHash == hash
        }
    }

    private func ownsExistingFile(path: String, marker: String, contentHash: String) -> Bool {
        guard let receipt else { return false }
        return receipt.entries.contains {
            $0.path == path && $0.marker == marker && $0.expectedHash == contentHash
        }
    }

    /// Hash of the entry as it currently exists in `file`, or `nil` when the
    /// entry is gone. Used to decide whether a receipt entry is safe to change.
    static func currentEntryHash(_ entry: InstalledEntry, in file: LoadedFile) throws -> String? {
        guard file.state.exists, !file.state.isDirectory else { return nil }
        switch entry.kind {
        case .hookConfig:
            switch entry.format {
            case .json:
                guard let data = file.data else { return nil }
                let root: JSONValue
                do {
                    root = try JSONValue.parse(data)
                } catch {
                    throw InstallerError.malformedJSON(path: entry.path, detail: String(describing: error))
                }
                guard let keyPath = entry.keyPath else { return nil }
                guard let value = try JSONMutation.value(in: root, keyPath: keyPath, marker: entry.marker) else {
                    return nil
                }
                return Digests.sha256(value.canonicalData())
            case .toml, .yaml, .text:
                guard let data = file.data else { return nil }
                let text = String(decoding: data, as: UTF8.self)
                guard case .found(_, let body) = MarkerBlock.locate(
                    in: text,
                    marker: entry.marker,
                    prefix: entry.format.blockCommentPrefix
                ) else {
                    return nil
                }
                return MarkerBlock.bodyHash(body)
            case .directory:
                return nil
            }
        case .pluginFile, .extensionFile, .commandWrapper:
            return file.state.sha256
        }
    }

    // MARK: Rendering

    private func templateValues(marker: String, target: String, generation: UInt64) -> [String: String] {
        Template.values(
            marker: marker,
            family: manifest.family,
            target: target,
            generation: generation,
            helperPath: helperPath
        )
    }

    private func assetURL(_ id: String) throws -> URL {
        guard let asset = manifest.asset(withID: id) else {
            throw InstallerError.invalidAsset(id: id, detail: "not declared by \(manifest.manifestPath)")
        }
        return PathRules.appending(asset.source, to: manifest.familyDirectory)
    }

    private func renderedTextAsset(
        _ id: String,
        marker: String,
        target: String,
        generation: UInt64
    ) throws -> String {
        let url = try assetURL(id)
        let data: Data
        do {
            data = try ConfigEditor.read(url)
        } catch {
            throw InstallerError.invalidAsset(id: id, detail: String(describing: error))
        }
        let text = String(decoding: data, as: UTF8.self)
        return Template.renderText(
            text,
            values: templateValues(marker: marker, target: target, generation: generation)
        )
    }

    /// Bytes this planner would write for one copy asset at a specific
    /// generation.
    ///
    /// `plan` renders at the next activation generation, so a fresh render
    /// never equals an installed file. Drift detection renders at the
    /// receipt's generation instead; only a moved helper path or a changed
    /// asset differs then.
    func renderedCopyAsset(
        assetID: String,
        marker: String,
        target: String,
        generation: UInt64
    ) throws -> Data {
        let text = try renderedTextAsset(
            assetID,
            marker: marker,
            target: target,
            generation: generation
        )
        return Data(text.utf8)
    }

    private func renderedJSONAsset(
        _ id: String,
        marker: String,
        target: String,
        generation: UInt64
    ) throws -> JSONValue {
        let url = try assetURL(id)
        let data: Data
        do {
            data = try ConfigEditor.read(url)
        } catch {
            throw InstallerError.invalidAsset(id: id, detail: String(describing: error))
        }
        let value: JSONValue
        do {
            value = try JSONValue.parse(data)
        } catch {
            throw InstallerError.invalidAsset(id: id, detail: "not valid JSON: \(error)")
        }
        return Template.renderJSON(
            value,
            values: templateValues(marker: marker, target: target, generation: generation)
        )
    }


    private func trim(_ value: String) -> String {
        var result = value
        while result.hasSuffix("\n") { result.removeLast() }
        return result
    }
}
