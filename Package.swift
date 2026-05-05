// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VibeController",
    platforms: [.macOS(.v11)],
    targets: [
        .executableTarget(
            name: "VibeController",
            path: "Sources/VibeController"
        )
    ]
)
