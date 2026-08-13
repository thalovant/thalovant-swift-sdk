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
        .target(name: "ThalovantSDK", path: "Sources/ThalovantSDK"),
        .testTarget(
            name: "ThalovantSDKTests",
            dependencies: ["ThalovantSDK"],
            path: "Tests/ThalovantSDKTests"
        ),
    ]
)
