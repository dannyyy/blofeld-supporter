// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Blofeld",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Blofeld",
            path: "Sources/Blofeld",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)
