// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "PendingBot",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "PendingBotMac", targets: ["PendingBotMac"]),
    ],
    dependencies: [
        .package(path: "../../shared/PendingBotShared"),
    ],
    targets: [
        .executableTarget(
            name: "PendingBotMac",
            dependencies: ["PendingBotShared"]
        ),
    ]
)
