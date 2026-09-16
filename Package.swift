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
        // zlib, for the metadata of a WIRE-1 frame the hub chose to compress.
        // The encoder picks per frame whichever of the two is shorter, so this
        // is not an optional path: without it a rendered utterance arrives with
        // no language and no filename beside it.
        .systemLibrary(name: "CZlibShim", path: "Sources/CZlibShim"),
        .target(name: "ThalovantSDK", dependencies: ["CThalovantNoise", "CZlibShim"], path: "Sources/ThalovantSDK", resources: [.copy("ListingData")]),
        .executableTarget(name: "ThalovantNoiseStoreFixture", dependencies: ["ThalovantSDK", "CThalovantNoise"], path: "Tests/NoiseStoreFixture"),
        .testTarget(
            name: "ThalovantSDKTests",
            dependencies: ["ThalovantSDK"],
            path: "Tests/ThalovantSDKTests",
            resources: [.copy("Fixtures/noise-node.json"), .copy("Fixtures/question-vectors.json"), .copy("Fixtures/inventory-vectors.json"), .copy("Fixtures/reply-claim-vectors.json"), .copy("Fixtures/listing-vectors.json"), .copy("Fixtures/language-matching-vectors.json"), .copy("Fixtures/conversation-vectors.json"), .copy("Fixtures/mesh-vectors.json"), .copy("Fixtures/binary-vectors.json"), .copy("Fixtures/binary-frames.json")]
        ),
    ]
)
