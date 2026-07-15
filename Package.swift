// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CopyCat",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.1"),
    ],
    targets: [
        .executableTarget(
            name: "CopyCat",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/CopyCat",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .define("ENABLE_SPARKLE"),
            ]),
        .testTarget(
            name: "CopyCatTests",
            dependencies: ["CopyCat"],
            path: "Tests/CopyCatTests"),
    ])
