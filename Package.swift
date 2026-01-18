// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BetterTabbing",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "BetterTabbing", targets: ["BetterTabbing"])
    ],
    targets: [
        .executableTarget(
            name: "BetterTabbing",
            path: "BetterTabbing/Sources",
            resources: [
                .process("../Resources")
            ]
        ),
        .testTarget(
            name: "BetterTabbingTests",
            dependencies: ["BetterTabbing"],
            path: "BetterTabbing/Tests"
        )
    ]
)
