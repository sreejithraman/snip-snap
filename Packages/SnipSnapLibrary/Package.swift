// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SnipSnapLibrary",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "SnipSnapCore", targets: ["SnipSnapCore"]),
        .library(name: "SnipSnapPersistence", targets: ["SnipSnapPersistence"]),
        .library(name: "SnipSnapCloud", targets: ["SnipSnapCloud"]),
        .library(name: "SnipSnapTestSupport", targets: ["SnipSnapTestSupport"]),
        .executable(name: "snipsnap", targets: ["SnipSnapCLI"]),
    ],
    targets: [
        .target(name: "SnipSnapCore"),
        .target(
            name: "SnipSnapPersistence",
            dependencies: ["SnipSnapCore"]
        ),
        .target(
            name: "SnipSnapCloud",
            dependencies: ["SnipSnapCore", "SnipSnapPersistence"]
        ),
        .executableTarget(
            name: "SnipSnapCLI",
            dependencies: ["SnipSnapCore", "SnipSnapPersistence"]
        ),
        .target(
            name: "SnipSnapTestSupport",
            dependencies: ["SnipSnapCore", "SnipSnapPersistence"],
            path: "Tests/SnipSnapTestSupport"
        ),
        .testTarget(
            name: "SnipSnapCoreTests",
            dependencies: ["SnipSnapCore"]
        ),
        .testTarget(
            name: "SnipSnapPersistenceTests",
            dependencies: ["SnipSnapCore", "SnipSnapPersistence", "SnipSnapTestSupport"]
        ),
        .testTarget(
            name: "SnipSnapCloudTests",
            dependencies: ["SnipSnapCore", "SnipSnapPersistence", "SnipSnapCloud", "SnipSnapTestSupport"]
        ),
        .testTarget(
            name: "SnipSnapCLITests",
            dependencies: ["SnipSnapCLI", "SnipSnapCore", "SnipSnapPersistence"]
        ),
    ]
)
