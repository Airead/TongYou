// swift-tools-version: 6.0
// This Package.swift exists solely to enable sourcekit-lsp indexing in VSCode.
// The actual build uses the Xcode project (TongYou.xcodeproj).

import PackageDescription

let package = Package(
    name: "TongYou",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "TongYou",
            path: "TongYou",
            exclude: ["Renderer/Shaders.metal"],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "TongYouTests",
            dependencies: ["TongYou"],
            path: "TongYouTests"
        ),
    ]
)
