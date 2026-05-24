// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "PendingBotCrew",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PendingBotCrew", targets: ["PendingBotCrew"])
    ],
    targets: [
        .executableTarget(
            name: "PendingBotCrew",
            path: "Sources/PendingBotCrew"
        )
    ]
)
