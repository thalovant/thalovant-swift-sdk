// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "NoiseInterop", platforms: [.macOS(.v12)],
    dependencies: [.package(name: "ThalovantSDK", path: "../..")],
    targets: [.executableTarget(name: "NoiseInterop", dependencies: [.product(name: "ThalovantSDK", package: "ThalovantSDK")])])
