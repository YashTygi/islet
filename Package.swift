// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Islet",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Islet", path: "Sources/Islet"),
        // `islet` CLI: lives inside the app bundle, talks to the app via distributed notifications.
        .executableTarget(name: "IsletCLI", path: "Sources/IsletCLI"),
    ]
)
