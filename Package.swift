// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexRunway",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .executable(name: "CodexRunway", targets: ["CodexRunway"]),
        .executable(name: "CodexRunwayCostBenchmark", targets: ["CodexRunwayCostBenchmark"]),
        .library(name: "CodexRunwayCore", targets: ["CodexRunwayCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.3"),
    ],
    targets: [
        .target(
            name: "CodexRunwayCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]),
        .target(
            name: "CodexRunwayWidget",
            dependencies: ["CodexRunwayCore"],
            resources: [.process("Resources")]),
        .executableTarget(
            name: "CodexRunway",
            dependencies: [
                "CodexRunwayCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ]),
        .executableTarget(
            name: "CodexRunwayCostBenchmark",
            dependencies: ["CodexRunwayCore"]),
        .testTarget(
            name: "CodexRunwayCoreTests",
            dependencies: ["CodexRunwayCore"]),
        .testTarget(
            name: "CodexRunwayTests",
            dependencies: ["CodexRunway", "CodexRunwayCore"]),
    ])
