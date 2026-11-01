// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AwakeLite",
    platforms: [.macOS(.v13)],
    targets: [
        // The library covers the whole non-UI source tree. App-only files are
        // compiled by build.sh instead, so integration code is covered by
        // `swift test` without pulling SwiftUI menu-bar sources in.
        .target(
            name: "AwakeLiteCore",
            path: "Sources",
            exclude: [
                "AwakeLiteApp.swift",
                "AwakeController.swift",
                "ProcessScanner.swift",
                "LoginItem.swift",
                // App-only UI added by the catalog-window unit; compiled by
                // build.sh, not by the library target.
                "IntegrationsView.swift"
            ],
            sources: ["Core", "Integrations"]
        ),
        .testTarget(
            name: "AwakeLiteCoreTests",
            dependencies: ["AwakeLiteCore"],
            path: "Tests/AwakeLiteCoreTests"
        )
    ]
)
