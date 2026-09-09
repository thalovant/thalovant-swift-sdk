// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ThalovantSDK",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "ThalovantSDK", targets: ["ThalovantSDK"]),
    ],
    targets: [
        .target(name: "CThalovantNoise", path: "Sources/CThalovantNoise", exclude: ["PROVENANCE.md", "source-hashes.json"], publicHeadersPath: "include"),
        .target(name: "ThalovantSDK", dependencies: ["CThalovantNoise"], path: "Sources/ThalovantSDK"),
        .testTarget(
            name: "ThalovantSDKTests",
            dependencies: ["ThalovantSDK"],
            path: "Tests/ThalovantSDKTests",
            resources: [.copy("Fixtures/noise-node.json")]
        ),
    ]
)
