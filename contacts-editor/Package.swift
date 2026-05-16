// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "contacts-editor",
    platforms: [.macOS(.v12)],
    targets: [
        .target(
            name: "ContactsEditorCore",
            path: "Sources/ContactsEditorCore"
        ),
        .executableTarget(
            name: "cli",
            dependencies: ["ContactsEditorCore"],
            path: "Sources/cli"
        ),
        .executableTarget(
            name: "ContactsEditorCoreTests",
            dependencies: ["ContactsEditorCore"],
            path: "Tests/ContactsEditorCoreTests"
        ),
    ]
)
