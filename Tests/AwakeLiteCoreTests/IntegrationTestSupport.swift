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

    /// The integration packages the app ships: OMP only after the first-version
    /// reset. `CatalogTests` asserts this surface explicitly.
    static var shippedIntegrationsRoot: URL {
        repositoryRoot.appendingPathComponent("Resources/Integrations", isDirectory: true)
    }

    /// Test-only packages. They keep the generic installer's format coverage
    /// (JSON, TOML, copy) alive until R4 replaces it with an OMP-specific
    /// installer. Nothing here ships or is loaded by the app.
    static var fixtureIntegrationsRoot: URL {
        repositoryRoot.appendingPathComponent(
            "Tests/AwakeLiteCoreTests/Fixtures/Integrations",
            isDirectory: true
        )
    }

    static func shippedCatalog() throws -> Catalog {
        try Catalog(loading: shippedIntegrationsRoot)
    }

    static func fixtureCatalog() throws -> Catalog {
        try Catalog(loading: fixtureIntegrationsRoot)
    }

    static let shippedFamilies = ["omp"]

    static let shippedTargetIDs = ["omp.cli"]

    /// Fixture families for the generic installer tests. OMP is shipped, not
    /// a fixture; its manifest is covered by `CatalogTests` and
    /// `OMPAdapterTests`.
    static let families = [
        "antigravity", "claude-code", "codex", "cursor", "opencode", "pi"
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
