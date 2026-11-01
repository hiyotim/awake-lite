// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AwakeLite",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "AwakeLiteCore", path: "Sources/Core"),
        .testTarget(
            name: "AwakeLiteCoreTests",
            dependencies: ["AwakeLiteCore"],
            path: "Tests/AwakeLiteCoreTests"
        )
    ]
)
