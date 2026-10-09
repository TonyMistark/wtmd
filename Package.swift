// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "wtmd",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "WTMarkdownKit",
            path: "Sources/WTMarkdownKit"
        ),
        .executableTarget(
            name: "wtmd",
            dependencies: ["WTMarkdownKit"],
            path: "Sources/wtmd"
        ),
        .testTarget(
            name: "WTMarkdownKitTests",
            dependencies: ["WTMarkdownKit"],
            path: "Tests/WTMarkdownKitTests"
        ),
        .testTarget(
            name: "wtmdTests",
            dependencies: ["wtmd", "WTMarkdownKit"],
            path: "Tests/wtmdTests"
        ),
    ]
)
