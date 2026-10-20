// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Islet",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Self-update. Release tools (generate_keys, sign_update) land in .build/artifacts/sparkle/Sparkle/bin.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .executableTarget(name: "Islet", dependencies: [.product(name: "Sparkle", package: "Sparkle")],
                          path: "Sources/Islet",
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        // `islet` CLI: lives inside the app bundle, talks to the app via distributed notifications.
        .executableTarget(name: "IsletCLI", path: "Sources/IsletCLI"),
    ]
)
