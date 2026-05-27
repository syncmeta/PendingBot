// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "PendingBotShared",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "PendingBotShared", targets: ["PendingBotShared"]),
    ],
    targets: [
        .target(name: "PendingBotShared"),
        .testTarget(
            name: "PendingBotSharedTests",
            dependencies: ["PendingBotShared"]
        ),
    ]
)
