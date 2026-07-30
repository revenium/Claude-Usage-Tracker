// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "UsageKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "UsageCore", type: .static, targets: ["UsageCore"]),
        .library(
            name: "CodexUsageProvider",
            type: .static,
            targets: ["CodexUsageProvider"]
        )
    ],
    targets: [
        .target(name: "UsageCore"),
        .target(
            name: "CodexUsageProvider",
            dependencies: ["UsageCore"]
        ),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"]
        ),
        .testTarget(
            name: "CodexUsageProviderTests",
            dependencies: ["CodexUsageProvider"],
            resources: [.copy("Fixtures")]
        )
    ]
)
