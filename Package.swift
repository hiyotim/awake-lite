// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AwakeLite",
    platforms: [.macOS(.v13)],
    targets: [
        // The library covers the whole non-UI source tree. App-only files are
        // compiled by build.sh instead, so integration and ingestion code is
        // covered by `swift test` without pulling SwiftUI menu-bar sources in.
        .target(
            name: "AwakeLiteCore",
            path: "Sources",
            exclude: [
                "AwakeLiteApp.swift",
                "AwakeController.swift",
                "LoginItem.swift",
                // App-only UI added by the catalog-window unit; compiled by
                // build.sh, not by the library target.
                "IntegrationsView.swift"
            ],
            sources: ["Core", "Integrations", "Adapters", "HookNormalizer.swift", "PowerAssertion.swift", "AppCoordinator.swift"]
        ),
        // The short-lived hook helper. It links the same library so the event
        // schema, the store, and the activation check have one implementation.
        .executableTarget(
            name: "AwakeLiteHelper",
            dependencies: ["AwakeLiteCore"],
            path: "Helper"
        ),
        .testTarget(
            name: "AwakeLiteCoreTests",
            dependencies: ["AwakeLiteCore"],
            path: "Tests/AwakeLiteCoreTests",
            // Installer-format fixtures are read from disk through #filePath,
            // not bundled as target resources.
            exclude: ["Fixtures"]
        )
    ]
)
