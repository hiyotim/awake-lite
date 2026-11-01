import CryptoKit
import Foundation

// MARK: - JSON value

/// Small JSON tree shared by the manifest reader and the declarative
/// configuration editor.
///
/// Foundation parses JSON; this type gives the installer a comparable,
/// deterministic representation so a value can be hashed, merged at one key,
/// and compared with what a previous installation recorded. It is not a vendor
/// payload parser and never sees harness event data.
enum JSONValue: Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double, isInteger: Bool)
    case bool(Bool)
    case null

    static func parse(_ data: Data) throws -> JSONValue {
        let any: Any
        do {
            any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw JSONValueError.notJSON
        }
        return try from(any)
    }

    static func from(_ any: Any) throws -> JSONValue {
        if any is NSNull { return .null }
        if let number = any as? NSNumber {
            // `Bool` bridges to `NSNumber`, so booleans are separated first.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let isInteger = !CFNumberIsFloatType(number)
            return .number(number.doubleValue, isInteger: isInteger)
        }
        if let dictionary = any as? [String: Any] {
            var result: [String: JSONValue] = [:]
            result.reserveCapacity(dictionary.count)
            for (key, value) in dictionary {
                result[key] = try from(value)
            }
            return .object(result)
        }
        if let array = any as? [Any] {
            return .array(try array.map(from))
        }
        if let string = any as? String {
            return .string(string)
        }
        throw JSONValueError.unsupportedValue(String(describing: type(of: any)))
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .number(let value, let isInteger) = self, isInteger,
           value >= Double(Int.min), value <= Double(Int.max) {
            return Int(value)
        }
        return nil
    }

    // MARK: Serialization

    /// Deterministic JSON bytes. Keys are sorted so equal values always hash
    /// equally, whichever dictionary produced them.
    func data(pretty: Bool) -> Data {
        var text = ""
        write(into: &text, indent: 0, pretty: pretty)
        if pretty { text += "\n" }
        return Data(text.utf8)
    }

    func canonicalData() -> Data {
        data(pretty: false)
    }

    private func write(into text: inout String, indent: Int, pretty: Bool) {
        switch self {
        case .object(let object):
            if object.isEmpty {
                text += "{}"
                return
            }
            text += "{"
            let keys = object.keys.sorted()
            for (index, key) in keys.enumerated() {
                if index > 0 { text += "," }
                if pretty {
                    text += "\n"
                    text += String(repeating: "  ", count: indent + 1)
                }
                text += JSONValue.quoted(key)
                text += pretty ? ": " : ":"
                object[key]?.write(into: &text, indent: indent + 1, pretty: pretty)
            }
            if pretty {
                text += "\n"
                text += String(repeating: "  ", count: indent)
            }
            text += "}"
        case .array(let array):
            if array.isEmpty {
                text += "[]"
                return
            }
            text += "["
            for (index, element) in array.enumerated() {
                if index > 0 { text += "," }
                if pretty {
                    text += "\n"
                    text += String(repeating: "  ", count: indent + 1)
                }
                element.write(into: &text, indent: indent + 1, pretty: pretty)
            }
            if pretty {
                text += "\n"
                text += String(repeating: "  ", count: indent)
            }
            text += "]"
        case .string(let value):
            text += JSONValue.quoted(value)
        case .number(let value, let isInteger):
            text += JSONValue.numberText(value, isInteger: isInteger)
        case .bool(let value):
            text += value ? "true" : "false"
        case .null:
            text += "null"
        }
    }

    static func quoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    static func numberText(_ value: Double, isInteger: Bool) -> String {
        if isInteger, value >= -9.007_199_254_740_992e15, value <= 9.007_199_254_740_992e15 {
            return String(Int64(value))
        }
        return String(value)
    }
}

enum JSONValueError: Error, Equatable, CustomStringConvertible {
    case notJSON
    case unsupportedValue(String)

    var description: String {
        switch self {
        case .notJSON:
            return "not valid JSON"
        case .unsupportedValue(let type):
            return "unsupported JSON value of type \(type)"
        }
    }
}

// MARK: - Digests

enum Digests {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ string: String) -> String {
        sha256(Data(string.utf8))
    }
}

// MARK: - Path rules

/// Paths in a manifest are always relative and are never allowed to escape the
/// root they are resolved against.
enum PathRules {
    /// Returns the components of a safe relative path, or `nil` when the value
    /// is absolute, empty, contains an empty component, or walks upwards.
    static func components(of relative: String) -> [String]? {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\0") else {
            return nil
        }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return nil }
        for part in parts where part.isEmpty || part == "." || part == ".." {
            return nil
        }
        return parts
    }

    static func isSafeRelativePath(_ relative: String) -> Bool {
        components(of: relative) != nil
    }

    static func appending(_ relative: String, to root: URL) -> URL {
        guard let parts = components(of: relative) else { return root }
        var url = root
        for part in parts { url.appendPathComponent(part) }
        return url
    }

    /// A marker must be a single-line identifier: it becomes a JSON key and a
    /// comment-line token.
    static func isSafeMarker(_ marker: String) -> Bool {
        guard !marker.isEmpty else { return false }
        return !marker.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F || CharacterSet.whitespaces.contains(scalar)
        }
    }

    /// A value usable as one path component: no separators, no traversal, and
    /// only `[A-Za-z0-9._-]`.
    static func isCanonicalComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            let code = scalar.value
            let keeps = (0x30...0x39).contains(code)
                || (0x41...0x5A).contains(code)
                || (0x61...0x7A).contains(code)
                || code == 0x5F
                || code == 0x2D
                || code == 0x2E
            return keeps
        }
    }
}

// MARK: - Manifest schema

enum IntegrationTargetMode: String, Codable, CaseIterable {
    case cli
    case desktop
}

enum TargetCapability: String, Codable, CaseIterable {
    case lifecycleHooks
    case snapshotAPI
    case inProcessExtension
    case readOnlyConnector
}

/// Declared evidence level. Discovery never changes it.
enum VerificationLevel: String, Codable, CaseIterable {
    case unverified
    case fixture
    case live
}

enum StepKind: String, Codable, CaseIterable {
    case hookConfig
    case pluginFile
    case extensionFile
    case commandWrapper

    /// Kinds whose step installs a file the app wholly owns.
    var isFileCopy: Bool {
        switch self {
        case .pluginFile, .extensionFile, .commandWrapper:
            return true
        case .hookConfig:
            return false
        }
    }
}

enum StepFormat: String, Codable, CaseIterable {
    case json
    case toml
    case yaml
    case text
    case directory

    /// Comment prefix used by marker-delimited blocks.
    var blockCommentPrefix: String { "#" }
}

/// Where a step's `configRoot` selector resolves. Only a home-relative
/// subpath or the app support root is expressible.
enum ConfigRootSpec: Equatable {
    case home(String)
    case appSupport

    static func parse(_ raw: String) -> ConfigRootSpec? {
        if raw == "${APPSUPPORT}" { return .appSupport }
        if raw.hasPrefix("~/") {
            let rest = String(raw.dropFirst(2))
            return PathRules.components(of: rest) != nil ? .home(rest) : nil
        }
        if raw.hasPrefix("$HOME/") {
            let rest = String(raw.dropFirst(6))
            return PathRules.components(of: rest) != nil ? .home(rest) : nil
        }
        return nil
    }

    func resolve(homeRoot: URL, appSupportRoot: URL) -> URL {
        switch self {
        case .home(let relative):
            return PathRules.appending(relative, to: homeRoot)
        case .appSupport:
            return appSupportRoot
        }
    }
}

struct PackageTarget: Equatable {
    var id: String
    var mode: IntegrationTargetMode
    var capabilities: [TargetCapability]
    var verificationLevel: VerificationLevel
}

struct PackageAsset: Equatable {
    var id: String
    /// Relative to the family directory inside the bundle.
    var source: String
    /// Relative to the installed package root.
    var destination: String
}

struct OwnedEntrySpec: Equatable {
    var marker: String
    var asset: String
}

struct PackageStep: Equatable {
    var kind: StepKind
    var target: String
    var format: StepFormat
    var configRoot: ConfigRootSpec
    var path: String
    var keyPath: [String]?
    var ownedEntries: [OwnedEntrySpec]
}

/// One bundled, trusted package. Declarative only: no command, address, or
/// executable field is expressible.
struct PackageManifest: Equatable {
    var schema: Int
    var family: String
    var displayName: String
    var packageVersion: String
    var requiresRestart: Bool
    var requiresHookTrust: Bool
    var notes: [String]
    var targets: [PackageTarget]
    var assets: [PackageAsset]
    var steps: [PackageStep]

    /// Absolute location of the family directory in the bundle.
    var familyDirectory: URL
    /// Human-readable manifest location used in every error message.
    var manifestPath: String

    func target(withID id: String) -> PackageTarget? {
        targets.first { $0.id == id }
    }

    func asset(withID id: String) -> PackageAsset? {
        assets.first { $0.id == id }
    }
}

// MARK: - Manifest errors

struct ManifestError: Error, Equatable, CustomStringConvertible {
    var manifest: String
    var field: String
    var reason: String

    var description: String {
        "\(manifest): \(field): \(reason)"
    }
}

// MARK: - Manifest reader

/// Strict reader for schema 1.
///
/// Every rule in the manifest contract is enforced here with the manifest path
/// and the offending field in the message, so a non-conforming bundle file is
/// reported instead of being accepted with a weakened interpretation.
struct PackageManifestReader {
    let manifestURL: URL
    let displayPath: String
    let familyDirectoryName: String

    static let topLevelKeys: Set<String> = [
        "schema", "family", "displayName", "packageVersion", "requiresRestart",
        "requiresHookTrust", "notes", "targets", "assets", "steps"
    ]
    static let targetKeys: Set<String> = ["id", "mode", "capabilities", "verificationLevel"]
    static let assetKeys: Set<String> = ["id", "source", "destination"]
    static let stepKeys: Set<String> = [
        "kind", "target", "format", "configRoot", "path", "keyPath", "ownedEntries"
    ]
    static let ownedEntryKeys: Set<String> = ["marker", "asset"]

    func read() throws -> PackageManifest {
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw fail("<root>", "cannot read manifest: \(error.localizedDescription)")
        }
        let root: JSONValue
        do {
            root = try JSONValue.parse(data)
        } catch {
            throw fail("<root>", "not valid JSON: \(error)")
        }
        guard let object = root.objectValue else {
            throw fail("<root>", "manifest must be a JSON object")
        }
        try checkUnknownKeys(object, allowed: Self.topLevelKeys, prefix: "")

        let schema = try requireInt(object, "schema")
        guard schema == 1 else {
            throw fail("schema", "unsupported schema \(schema); this build reads schema 1 only")
        }

        let family = try requireNonEmptyString(object, "family")
        guard family == familyDirectoryName else {
            throw fail(
                "family",
                "\"\(family)\" does not match the containing directory \"\(familyDirectoryName)\""
            )
        }
        guard PathRules.isCanonicalComponent(family) else {
            throw fail("family", "\"\(family)\" is not a canonical family identifier")
        }

        let displayName = try requireNonEmptyString(object, "displayName")
        let packageVersion = try requireNonEmptyString(object, "packageVersion")
        let requiresRestart = try requireBool(object, "requiresRestart")
        let requiresHookTrust = try requireBool(object, "requiresHookTrust")
        let notes = try requireStringArray(object, "notes", prefix: "notes")

        let targets = try readTargets(object, family: family)
        let assets = try readAssets(object)
        let steps = try readSteps(object, family: family, targets: targets, assets: assets)

        return PackageManifest(
            schema: schema,
            family: family,
            displayName: displayName,
            packageVersion: packageVersion,
            requiresRestart: requiresRestart,
            requiresHookTrust: requiresHookTrust,
            notes: notes,
            targets: targets,
            assets: assets,
            steps: steps,
            familyDirectory: familyDirectoryName.isEmpty ? manifestURL.deletingLastPathComponent()
                : manifestURL.deletingLastPathComponent(),
            manifestPath: displayPath
        )
    }

    // MARK: Targets

    private func readTargets(_ object: [String: JSONValue], family: String) throws -> [PackageTarget] {
        guard let rawTargets = object["targets"]?.arrayValue else {
            throw fail("targets", "must be a non-empty array")
        }
        guard !rawTargets.isEmpty else {
            throw fail("targets", "must not be empty")
        }
        var seen: Set<String> = []
        var result: [PackageTarget] = []
        for (index, element) in rawTargets.enumerated() {
            let field = "targets[\(index)]"
            guard let target = element.objectValue else {
                throw fail(field, "must be an object")
            }
            try checkUnknownKeys(target, allowed: Self.targetKeys, prefix: field)
            let id = try requireNonEmptyString(target, "id", prefix: field)
            let prefix = "\(family)."
            let suffix = id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : ""
            guard !suffix.isEmpty, !suffix.contains("."),
                  PathRules.isCanonicalComponent(suffix) else {
                throw fail(
                    "\(field).id",
                    "\"\(id)\" must be \"<family>.<suffix>\" with family \"\(family)\""
                )
            }
            guard seen.insert(id).inserted else {
                throw fail("\(field).id", "duplicate compatibility target \"\(id)\"")
            }
            let mode = try requireEnum(target, "mode", prefix: field, allowed: IntegrationTargetMode.allCases)
            let capabilities = try requireEnumArray(
                target,
                "capabilities",
                prefix: field,
                allowed: TargetCapability.allCases
            )
            let level = try requireEnum(
                target,
                "verificationLevel",
                prefix: field,
                allowed: VerificationLevel.allCases
            )
            result.append(
                PackageTarget(id: id, mode: mode, capabilities: capabilities, verificationLevel: level)
            )
        }
        return result
    }

    // MARK: Assets

    private func readAssets(_ object: [String: JSONValue]) throws -> [PackageAsset] {
        guard let rawAssets = object["assets"] else {
            throw fail("assets", "must be an array")
        }
        guard let assets = rawAssets.arrayValue else {
            throw fail("assets", "must be an array")
        }
        var ids: Set<String> = []
        var destinations: Set<String> = []
        var result: [PackageAsset] = []
        for (index, element) in assets.enumerated() {
            let field = "assets[\(index)]"
            guard let asset = element.objectValue else {
                throw fail(field, "must be an object")
            }
            try checkUnknownKeys(asset, allowed: Self.assetKeys, prefix: field)
            let id = try requireNonEmptyString(asset, "id", prefix: field)
            guard PathRules.isCanonicalComponent(id) else {
                throw fail("\(field).id", "\"\(id)\" is not a canonical asset identifier")
            }
            guard ids.insert(id).inserted else {
                throw fail("\(field).id", "duplicate asset id \"\(id)\"")
            }

            let source = try requireNonEmptyString(asset, "source", prefix: field)
            guard PathRules.isSafeRelativePath(source) else {
                throw fail(
                    "\(field).source",
                    "\"\(source)\" must be a relative path inside the family directory"
                )
            }
            try requireBundledRegularFile(source, field: "\(field).source")

            let destination = try requireNonEmptyString(asset, "destination", prefix: field)
            guard PathRules.isSafeRelativePath(destination) else {
                throw fail(
                    "\(field).destination",
                    "\"\(destination)\" must be a relative path inside the package root"
                )
            }
            guard destinations.insert(destination).inserted else {
                throw fail("\(field).destination", "duplicate destination \"\(destination)\"")
            }
            result.append(PackageAsset(id: id, source: source, destination: destination))
        }
        return result
    }

    /// The source must exist as a regular file and no component from the
    /// family directory down may be a symlink.
    private func requireBundledRegularFile(_ source: String, field: String) throws {
        let familyDirectory = manifestURL.deletingLastPathComponent()
        let components = PathRules.components(of: source) ?? []
        var current = familyDirectory
        for (index, component) in components.enumerated() {
            current.appendPathComponent(component)
            var info = stat()
            guard lstat(current.path, &info) == 0 else {
                throw fail(field, "asset source \"\(source)\" does not exist in the bundle")
            }
            let isLast = index == components.count - 1
            if isLast {
                guard (info.st_mode & S_IFMT) == S_IFREG else {
                    throw fail(field, "asset source \"\(source)\" is not a regular file")
                }
            } else {
                guard (info.st_mode & S_IFMT) == S_IFDIR else {
                    throw fail(field, "asset source \"\(source)\" has a non-directory component")
                }
            }
        }

        // Every asset is a template. An unknown `{token}` would be shipped
        // verbatim, so it is refused here rather than at apply time.
        let assetURL = PathRules.appending(source, to: familyDirectory)
        guard let data = try? ConfigEditor.read(assetURL) else {
            throw fail(field, "asset source \"\(source)\" cannot be read")
        }
        if let text = String(data: data, encoding: .utf8),
           let unknown = Template.firstUnknownPlaceholder(in: text) {
            throw fail(
                field,
                "unknown placeholder \"{\(unknown)}\"; allowed placeholders are "
                    + Template.allowed.map { "{\($0)}" }.joined(separator: ", ")
            )
        }
    }

    // MARK: Steps

    private func readSteps(
        _ object: [String: JSONValue],
        family: String,
        targets: [PackageTarget],
        assets: [PackageAsset]
    ) throws -> [PackageStep] {
        guard let rawSteps = object["steps"]?.arrayValue else {
            throw fail("steps", "must be a non-empty array")
        }
        guard !rawSteps.isEmpty else {
            throw fail("steps", "must not be empty")
        }
        let targetIDs = Set(targets.map(\.id))
        let assetIDs = Set(assets.map(\.id))
        var stepMarkers: Set<String> = []
        var result: [PackageStep] = []

        for (index, element) in rawSteps.enumerated() {
            let field = "steps[\(index)]"
            guard let step = element.objectValue else {
                throw fail(field, "must be an object")
            }
            // Unknown keys are refused here: this is what keeps an executable
            // or network field out of a trusted manifest.
            try checkUnknownKeys(step, allowed: Self.stepKeys, prefix: field)

            let kind = try requireEnum(step, "kind", prefix: field, allowed: StepKind.allCases)
            let format = try requireEnum(step, "format", prefix: field, allowed: StepFormat.allCases)
            let target = try requireNonEmptyString(step, "target", prefix: field)
            guard targetIDs.contains(target) else {
                throw fail("\(field).target", "\"\(target)\" is not a target of this package")
            }

            let rawRoot = try requireNonEmptyString(step, "configRoot", prefix: field)
            guard let configRoot = ConfigRootSpec.parse(rawRoot) else {
                throw fail(
                    "\(field).configRoot",
                    "\"\(rawRoot)\" must start with \"~/\", \"$HOME/\", or be exactly \"${APPSUPPORT}\""
                )
            }

            let path = try requireNonEmptyString(step, "path", prefix: field)
            guard PathRules.isSafeRelativePath(path) else {
                throw fail("\(field).path", "\"\(path)\" must be a relative path without \"..\"")
            }

            var keyPath: [String]?
            if let rawKeyPath = step["keyPath"] {
                guard let elements = rawKeyPath.arrayValue else {
                    throw fail("\(field).keyPath", "must be an array of non-empty strings")
                }
                guard !elements.isEmpty else {
                    throw fail("\(field).keyPath", "must not be empty")
                }
                var values: [String] = []
                for (keyIndex, element) in elements.enumerated() {
                    guard let value = element.stringValue, !value.isEmpty else {
                        throw fail(
                            "\(field).keyPath[\(keyIndex)]",
                            "must be a non-empty string"
                        )
                    }
                    values.append(value)
                }
                keyPath = values
            }
            guard format == .json || keyPath == nil else {
                throw fail("\(field).keyPath", "is only valid for format \"json\"")
            }
            if kind == .hookConfig, format == .json, keyPath == nil {
                throw fail("\(field).keyPath", "is required for a JSON hookConfig step")
            }

            guard let rawEntries = step["ownedEntries"]?.arrayValue else {
                throw fail("\(field).ownedEntries", "must be a non-empty array")
            }
            guard !rawEntries.isEmpty else {
                throw fail("\(field).ownedEntries", "must not be empty")
            }
            var entries: [OwnedEntrySpec] = []
            for (entryIndex, element) in rawEntries.enumerated() {
                let entryField = "\(field).ownedEntries[\(entryIndex)]"
                guard let entry = element.objectValue else {
                    throw fail(entryField, "must be an object")
                }
                try checkUnknownKeys(entry, allowed: Self.ownedEntryKeys, prefix: entryField)
                let marker = try requireNonEmptyString(entry, "marker", prefix: entryField)
                guard PathRules.isSafeMarker(marker) else {
                    throw fail("\(entryField).marker", "must be a single-line identifier")
                }
                guard stepMarkers.insert(marker).inserted else {
                    throw fail("\(entryField).marker", "duplicate marker \"\(marker)\"")
                }
                let assetID = try requireNonEmptyString(entry, "asset", prefix: entryField)
                guard assetIDs.contains(assetID) else {
                    throw fail("\(entryField).asset", "\"\(assetID)\" is not an asset of this package")
                }
                entries.append(OwnedEntrySpec(marker: marker, asset: assetID))
            }

            result.append(
                PackageStep(
                    kind: kind,
                    target: target,
                    format: format,
                    configRoot: configRoot,
                    path: path,
                    keyPath: keyPath,
                    ownedEntries: entries
                )
            )
        }
        return result
    }

    // MARK: Reading helpers

    private func fail(_ field: String, _ reason: String) -> ManifestError {
        ManifestError(manifest: displayPath, field: field, reason: reason)
    }

    private func checkUnknownKeys(
        _ object: [String: JSONValue],
        allowed: Set<String>,
        prefix: String
    ) throws {
        for key in object.keys.sorted() where !allowed.contains(key) {
            let field = prefix.isEmpty ? key : "\(prefix).\(key)"
            throw fail(field, "unknown field")
        }
    }

    private func requireNonEmptyString(
        _ object: [String: JSONValue],
        _ key: String,
        prefix: String = ""
    ) throws -> String {
        let field = prefix.isEmpty ? key : "\(prefix).\(key)"
        guard let value = object[key]?.stringValue else {
            throw fail(field, "must be a string")
        }
        guard !value.isEmpty else {
            throw fail(field, "must not be empty")
        }
        return value
    }

    private func requireInt(_ object: [String: JSONValue], _ key: String) throws -> Int {
        guard let value = object[key]?.intValue else {
            throw fail(key, "must be an integer")
        }
        return value
    }

    private func requireBool(_ object: [String: JSONValue], _ key: String) throws -> Bool {
        guard let value = object[key]?.boolValue else {
            throw fail(key, "must be a boolean")
        }
        return value
    }

    private func requireStringArray(
        _ object: [String: JSONValue],
        _ key: String,
        prefix: String
    ) throws -> [String] {
        guard let elements = object[key]?.arrayValue else {
            throw fail(prefix.isEmpty ? key : "\(prefix).\(key)", "must be an array of strings")
        }
        var result: [String] = []
        for (index, element) in elements.enumerated() {
            guard let value = element.stringValue else {
                throw fail("\(prefix.isEmpty ? key : prefix)[\(index)]", "must be a string")
            }
            result.append(value)
        }
        return result
    }

    private func requireEnum<T: RawRepresentable & CaseIterable>(
        _ object: [String: JSONValue],
        _ key: String,
        prefix: String,
        allowed: [T]
    ) throws -> T where T.RawValue == String {
        let field = prefix.isEmpty ? key : "\(prefix).\(key)"
        guard let raw = object[key]?.stringValue else {
            throw fail(field, "must be a string")
        }
        guard let value = T(rawValue: raw) else {
            throw fail(field, "unknown value \"\(raw)\"; expected one of \(allowed.map(\.rawValue).joined(separator: ", "))")
        }
        return value
    }

    private func requireEnumArray<T: RawRepresentable & CaseIterable>(
        _ object: [String: JSONValue],
        _ key: String,
        prefix: String,
        allowed: [T]
    ) throws -> [T] where T.RawValue == String {
        let field = prefix.isEmpty ? key : "\(prefix).\(key)"
        guard let elements = object[key]?.arrayValue else {
            throw fail(field, "must be an array of strings")
        }
        var result: [T] = []
        for (index, element) in elements.enumerated() {
            guard let raw = element.stringValue else {
                throw fail("\(field)[\(index)]", "must be a string")
            }
            guard let value = T(rawValue: raw) else {
                throw fail(
                    "\(field)[\(index)]",
                    "unknown value \"\(raw)\"; expected one of \(allowed.map(\.rawValue).joined(separator: ", "))"
                )
            }
            result.append(value)
        }
        return result
    }
}
