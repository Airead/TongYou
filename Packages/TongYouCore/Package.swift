// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TongYouCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TYTerminal", targets: ["TYTerminal"]),
        .library(name: "TYProtocol", targets: ["TYProtocol"]),
        .library(name: "TYPTY", targets: ["TYPTY"]),
        .library(name: "TYShell", targets: ["TYShell"]),
        .library(name: "TYServer", targets: ["TYServer"]),
        .executable(name: "tyd", targets: ["tyd"]),
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

        // Binary wire protocol for client/server communication.
        .target(
            name: "TYProtocol",
            dependencies: ["TYTerminal"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Server daemon: manages PTY sessions, serves clients over Unix socket.
        .target(
            name: "TYServer",
            dependencies: ["TYTerminal", "TYPTY", "TYProtocol", "TYShell"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // tyd executable: the server daemon entry point.
        .executableTarget(
            name: "tyd",
            dependencies: ["TYServer"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .testTarget(
            name: "TYTerminalTests",
            dependencies: ["TYTerminal"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .testTarget(
            name: "TYProtocolTests",
            dependencies: ["TYProtocol", "TYTerminal"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .testTarget(
            name: "TYServerTests",
            dependencies: ["TYServer", "TYProtocol", "TYTerminal"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
