// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CatapultPocket",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "CatapultPocketCore", targets: ["CatapultPocketCore"]),
        .library(name: "CatapultPocketUI", targets: ["CatapultPocketUI"])
    ],
    targets: [
        .target(name: "CatapultPocketCore"),
        .target(name: "CatapultPocketUI", dependencies: ["CatapultPocketCore"]),
        .testTarget(name: "CatapultPocketCoreTests", dependencies: ["CatapultPocketCore"])
    ]
)
