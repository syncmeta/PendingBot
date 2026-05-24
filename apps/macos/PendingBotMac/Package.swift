// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "PendingBotMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PendingBotMac", targets: ["PendingBotMac"])
    ],
    targets: [
        .executableTarget(
            name: "PendingBotMac",
            path: "Sources/PendingBotMac"
        )
    ]
)

