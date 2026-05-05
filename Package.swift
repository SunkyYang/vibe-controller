// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DualSenseWhispr",
    platforms: [.macOS(.v11)],
    targets: [
        .executableTarget(
            name: "DualSenseWhispr",
            path: "Sources/DualSenseWhispr"
        )
    ]
)
