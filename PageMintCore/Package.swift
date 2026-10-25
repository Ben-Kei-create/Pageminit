// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PageMintCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PageMintCore", targets: ["PageMintCore"]),
        .executable(name: "pagemint-spike", targets: ["pagemint-spike"]),
    ],
    targets: [
        .target(name: "PageMintCore"),
        .executableTarget(name: "pagemint-spike", dependencies: ["PageMintCore"]),
        .testTarget(name: "PageMintCoreTests", dependencies: ["PageMintCore"]),
    ]
)
