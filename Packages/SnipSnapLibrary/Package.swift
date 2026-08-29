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
        .testTarget(
            name: "SnipSnapPersistenceTests",
            dependencies: ["SnipSnapCore", "SnipSnapPersistence"]
        ),
        .testTarget(
            name: "SnipSnapCloudTests",
            dependencies: ["SnipSnapCore", "SnipSnapPersistence", "SnipSnapCloud"]
        ),
    ]
)
