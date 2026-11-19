// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PanoramaCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PanoramaCore", targets: ["PanoramaCore"]),
    ],
    targets: [
        .target(name: "PanoramaCore"),
        .executableTarget(name: "pano-replay", dependencies: ["PanoramaCore"]),
        .testTarget(name: "PanoramaCoreTests", dependencies: ["PanoramaCore"]),
    ]
)
