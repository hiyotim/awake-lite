import Darwin
import Foundation

// MARK: - Catalog

/// The bundled package catalog.
///
/// Loading validates every manifest in the root and the cross-manifest rules
/// that a single file cannot check: marker uniqueness and target-id
/// uniqueness. Nothing here parses vendor payloads or reads user settings.
struct Catalog {
    /// Directory that holds the seven family directories.
    let root: URL
    /// Family identifier to validated manifest.
    let manifests: [String: PackageManifest]

    /// Loads every `<root>/<family>/manifest.json`. Directory names are what
    /// the manifests must agree with; no per-family target list is hardcoded
    /// here.
    init(loading root: URL) throws {
        let manager = FileManager.default
        var isDirectory = ObjCBool(false)
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CatalogError.missingRoot(root.path)
        }
        let names: [String]
        do {
            names = try manager.contentsOfDirectory(atPath: root.path).sorted()
        } catch {
            throw CatalogError.unreadable(root.path, error.localizedDescription)
        }

        var loaded: [String: PackageManifest] = [:]
        var markerOwners: [String: String] = [:]
        var targetOwners: [String: String] = [:]

        for name in names {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            var directoryInfo = ObjCBool(false)
            guard manager.fileExists(atPath: directory.path, isDirectory: &directoryInfo),
                  directoryInfo.boolValue else {
                continue
            }
            let manifestURL = directory.appendingPathComponent("manifest.json")
            guard manager.fileExists(atPath: manifestURL.path) else { continue }
            let reader = PackageManifestReader(
                manifestURL: manifestURL,
                displayPath: "\(name)/manifest.json",
                familyDirectoryName: name
            )
            let manifest = try reader.read()

            for step in manifest.steps {
                for entry in step.ownedEntries {
                    if let owner = markerOwners[entry.marker] {
                        throw CatalogError.duplicateMarker(
                            marker: entry.marker,
                            first: owner,
                            second: manifest.manifestPath
                        )
                    }
                    markerOwners[entry.marker] = manifest.manifestPath
                }
            }
            for target in manifest.targets {
                if let owner = targetOwners[target.id] {
                    throw CatalogError.duplicateTarget(target: target.id, first: owner, second: manifest.manifestPath)
                }
                targetOwners[target.id] = manifest.manifestPath
            }

            loaded[manifest.family] = manifest
        }

        guard !loaded.isEmpty else {
            throw CatalogError.noManifests(root.path)
        }
        self.root = root
        self.manifests = loaded
    }

    /// Families in directory-name order. The card order is stable across runs.
    var allManifests: [PackageManifest] {
        manifests.values.sorted { $0.family < $1.family }
    }

    var familyNames: [String] {
        allManifests.map(\.family)
    }

    /// Every compatibility target in the catalog.
    var compatibilityTargets: [PackageTarget] {
        allManifests.flatMap(\.targets)
    }

    var compatibilityTargetIDs: [String] {
        compatibilityTargets.map(\.id).sorted()
    }

    func manifest(for family: String) throws -> PackageManifest {
        guard let manifest = manifests[family] else {
            throw InstallerError.unknownFamily(family)
        }
        return manifest
    }

    /// Availability per target for one family. Discovery reads files only and
    /// never changes `verificationLevel`.
    func targetStatuses(for family: String, discovery: ProductDiscovery) throws -> [TargetStatus] {
        let manifest = try manifest(for: family)
        return manifest.targets.map { target in
            let availability = discovery.availability(for: target.id)
            return TargetStatus(
                id: target.id,
                mode: target.mode,
                capabilities: target.capabilities,
                /// Deeper levels require a fixture or a recorded live check.
                verificationLevel: target.verificationLevel,
                isAvailable: availability.isAvailable,
                presentPaths: availability.presentPaths,
                searchedPaths: availability.searchedPaths
            )
        }
    }
}

enum CatalogError: Error, Equatable, CustomStringConvertible {
    case missingRoot(String)
    case noManifests(String)
    case unreadable(String, String)
    case duplicateMarker(marker: String, first: String, second: String)
    case duplicateTarget(target: String, first: String, second: String)

    var description: String {
        switch self {
        case .missingRoot(let path):
            return "catalog root \(path) does not exist"
        case .noManifests(let path):
            return "catalog root \(path) contains no manifest.json"
        case .unreadable(let path, let detail):
            return "catalog root \(path) cannot be read: \(detail)"
        case .duplicateMarker(let marker, let first, let second):
            return "marker \"\(marker)\" is declared by both \(first) and \(second); markers must be unique across the catalog"
        case .duplicateTarget(let target, let first, let second):
            return "target \"\(target)\" is declared by both \(first) and \(second)"
        }
    }
}

// MARK: - Target status

/// One compatibility target with declared evidence and observed availability.
struct TargetStatus: Equatable {
    var id: String
    var mode: IntegrationTargetMode
    var capabilities: [TargetCapability]
    /// Exactly what the manifest declared. Discovery never raises it.
    var verificationLevel: VerificationLevel
    var isAvailable: Bool
    var presentPaths: [String]
    var searchedPaths: [String]
}

// MARK: - Product discovery

/// Local-only availability checks.
///
/// Candidates are documented default install locations, resolved against an
/// injected home root and application roots. Discovery never launches a
/// product, never runs a subprocess, and never changes a verification level.
struct ProductDiscovery {
    enum CandidateKind: Equatable {
        case executable
        case application
    }

    enum CandidateRoot: Equatable {
        case home
        case applications
    }

    struct Candidate: Equatable {
        var root: CandidateRoot
        var relativePath: String
        var kind: CandidateKind
    }

    struct Availability: Equatable {
        var targetID: String
        var isAvailable: Bool
        var presentPaths: [String]
        var searchedPaths: [String]
    }

    var homeRoot: URL
    var applicationRoots: [URL]

    init(homeRoot: URL, applicationRoots: [URL]? = nil) {
        self.homeRoot = homeRoot
        if let applicationRoots {
            self.applicationRoots = applicationRoots
        } else {
            self.applicationRoots = [
                homeRoot.appendingPathComponent("Applications", isDirectory: true),
                URL(fileURLWithPath: "/Applications", isDirectory: true)
            ]
        }
    }

    /// Documented default locations for the ten compatibility targets. A
    /// product installed elsewhere stays reported as absent; the catalog never
    /// guesses, and absence never changes a verification level.
    static let candidates: [String: [Candidate]] = [
        "claude-code.cli": [
            Candidate(root: .home, relativePath: ".local/bin/claude", kind: .executable),
            Candidate(root: .home, relativePath: ".claude/local/claude", kind: .executable)
        ],
        "claude-code.desktop": [
            Candidate(root: .applications, relativePath: "Claude.app", kind: .application)
        ],
        "codex.cli": [
            Candidate(root: .home, relativePath: ".local/bin/codex", kind: .executable),
            Candidate(root: .home, relativePath: ".npm-global/bin/codex", kind: .executable)
        ],
        "codex.desktop": [
            Candidate(root: .applications, relativePath: "Codex.app", kind: .application)
        ],
        "cursor.desktop": [
            Candidate(root: .applications, relativePath: "Cursor.app", kind: .application)
        ],
        "antigravity.cli": [
            Candidate(root: .home, relativePath: ".local/bin/antigravity", kind: .executable),
            Candidate(root: .home, relativePath: ".antigravity/bin/antigravity", kind: .executable)
        ],
        "antigravity.desktop": [
            Candidate(root: .applications, relativePath: "Antigravity.app", kind: .application)
        ],
        "pi.cli": [
            Candidate(root: .home, relativePath: ".local/bin/pi", kind: .executable),
            Candidate(root: .home, relativePath: ".npm-global/bin/pi", kind: .executable)
        ],
        "omp.cli": [
            Candidate(root: .home, relativePath: ".local/bin/omp", kind: .executable),
            Candidate(root: .home, relativePath: ".bun/bin/omp", kind: .executable)
        ],
        "opencode.tui": [
            Candidate(root: .home, relativePath: ".local/bin/opencode", kind: .executable),
            Candidate(root: .home, relativePath: ".bun/bin/opencode", kind: .executable),
            Candidate(root: .home, relativePath: ".opencode/bin/opencode", kind: .executable)
        ]
    ]

    func availability(for targetID: String) -> Availability {
        let candidates = Self.candidates[targetID] ?? []
        var searched: [String] = []
        var present: [String] = []
        for candidate in candidates {
            for url in resolvedURLs(for: candidate) {
                searched.append(url.path)
                guard isPresent(url, kind: candidate.kind) else { continue }
                present.append(url.path)
            }
        }
        return Availability(
            targetID: targetID,
            isAvailable: !present.isEmpty,
            presentPaths: present,
            searchedPaths: searched
        )
    }

    private func resolvedURLs(for candidate: Candidate) -> [URL] {
        switch candidate.root {
        case .home:
            return [PathRules.appending(candidate.relativePath, to: homeRoot)]
        case .applications:
            return applicationRoots.map { PathRules.appending(candidate.relativePath, to: $0) }
        }
    }

    private func isPresent(_ url: URL, kind: CandidateKind) -> Bool {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return false }
        switch kind {
        case .executable:
            guard (info.st_mode & S_IFMT) == S_IFREG else { return false }
            return access(url.path, X_OK) == 0
        case .application:
            guard (info.st_mode & S_IFMT) == S_IFDIR else { return false }
            let plist = url.appendingPathComponent("Contents/Info.plist")
            return FileManager.default.fileExists(atPath: plist.path)
        }
    }
}
