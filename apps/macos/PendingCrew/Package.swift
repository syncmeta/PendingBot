// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "PendingCrew",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PendingCrew", targets: ["PendingCrew"])
    ],
    targets: [
        .executableTarget(
            name: "PendingCrew",
            path: "Sources/PendingCrew"
        )
    ]
)
