// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CaptureSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CaptureSpike",
            path: "Sources/CaptureSpike"
        )
    ]
)
