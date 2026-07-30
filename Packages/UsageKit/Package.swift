// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "UsageKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "UsageCore", type: .static, targets: ["UsageCore"])
    ],
    targets: [
        .target(name: "UsageCore"),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"]
        )
    ]
)
