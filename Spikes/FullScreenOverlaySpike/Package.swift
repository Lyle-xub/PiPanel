// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FullScreenOverlaySpike",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FullScreenOverlaySpike",
            path: "Sources/FullScreenOverlaySpike"
        )
    ]
)
