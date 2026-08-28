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
    ],
    targets: [
        .target(name: "SnipSnapCore"),
        .target(
            name: "SnipSnapPersistence",
            dependencies: ["SnipSnapCore"]
        ),
        .testTarget(
            name: "SnipSnapPersistenceTests",
            dependencies: ["SnipSnapCore", "SnipSnapPersistence"]
        ),
    ]
)
