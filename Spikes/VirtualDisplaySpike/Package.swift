// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VirtualDisplaySpike",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CGVirtualDisplayC",
            path: "Sources/CGVirtualDisplayC",
            linkerSettings: [
                .linkedFramework("CoreGraphics")
            ]
        ),
        .executableTarget(
            name: "VirtualDisplaySpike",
            dependencies: ["CGVirtualDisplayC"],
            path: "Sources/VirtualDisplaySpike"
        )
    ]
)
