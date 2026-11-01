import Foundation
@testable import AwakeLiteCore

/// Paths and temporary roots shared by the integration tests.
enum IntegrationFixtures {
    /// Repository root, derived from this file's location so the tests read
    /// the real bundled manifests instead of a copy.
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static var integrationsRoot: URL {
        repositoryRoot.appendingPathComponent("Resources/Integrations", isDirectory: true)
    }

    static func bundledCatalog() throws -> Catalog {
        try Catalog(loading: integrationsRoot)
    }

    static let families = [
        "antigravity", "claude-code", "codex", "cursor", "omp", "opencode", "pi"
    ]

    static let targetIDs = [
        "claude-code.cli", "claude-code.desktop",
        "codex.cli", "codex.desktop",
        "cursor.desktop",
        "antigravity.cli", "antigravity.desktop",
        "pi.cli", "omp.cli", "opencode.tui"
    ]

    /// Unique temporary sandbox removed by the caller.
    static func makeSandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AwakeLiteIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(text.utf8).write(to: url)
    }

    /// Every regular file below `root`, sorted by path.
    static func files(under root: URL) -> [URL] {
        var result: [URL] = []
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        for case let url as URL in enumerator {
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            result.append(url)
        }
        return result.sorted { $0.path < $1.path }
    }

    static func jsonObject(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return object
    }
}
