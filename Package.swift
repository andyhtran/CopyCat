// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CopyCat",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CopyCat",
            path: "Sources/CopyCat",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]),
        .testTarget(
            name: "CopyCatTests",
            dependencies: ["CopyCat"],
            path: "Tests/CopyCatTests"),
    ])
