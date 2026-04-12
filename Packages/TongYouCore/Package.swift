// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TongYouCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TYTerminal", targets: ["TYTerminal"]),
        .library(name: "TYPTY", targets: ["TYPTY"]),
        .library(name: "TYShell", targets: ["TYShell"]),
    ],
    targets: [
        // Pure terminal state machine: Screen, VTParser, StreamHandler, etc.
        .target(
            name: "TYTerminal",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // C helpers for PTY operations (fork, cwd query, fg process name).
        .target(
            name: "TYPTYC",
            publicHeadersPath: "include",
            cSettings: [
                .define("_POSIX_C_SOURCE", to: "200809L", .when(platforms: [.linux])),
            ]
        ),

        // PTY process management.
        .target(
            name: "TYPTY",
            dependencies: ["TYTerminal", "TYPTYC", "TYShell"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Shell integration scripts and injector.
        .target(
            name: "TYShell",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .testTarget(
            name: "TYTerminalTests",
            dependencies: ["TYTerminal"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
