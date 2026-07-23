// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bandwatch",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "BandwatchCore"),
        .executableTarget(
            name: "Bandwatch",
            dependencies: ["BandwatchCore"]
        ),
        .testTarget(
            name: "BandwatchCoreTests",
            dependencies: ["BandwatchCore"]
        ),
    ]
)
