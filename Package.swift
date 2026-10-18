// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MyNotch", path: "Sources/MyNotch"),
        // `notch` CLI: lives inside the app bundle, talks to the app via distributed notifications.
        .executableTarget(name: "notch", path: "Sources/notch"),
    ]
)
