// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "contacts-pinyin",
    platforms: [.macOS(.v12)],
    targets: [
        .target(
            name: "ContactsPinyinCore",
            path: "Sources/ContactsPinyinCore"
        ),
        .executableTarget(
            name: "cli",
            dependencies: ["ContactsPinyinCore"],
            path: "Sources/cli"
        ),
        .testTarget(
            name: "ContactsPinyinCoreTests",
            dependencies: ["ContactsPinyinCore"],
            path: "Tests/ContactsPinyinCoreTests"
        ),
    ]
)
