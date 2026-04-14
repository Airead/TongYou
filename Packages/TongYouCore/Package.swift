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
        .library(name: "TYClient", targets: ["TYClient"]),
        .executable(name: "tongyou", targets: ["tongyou"]),
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

        // Client library: connects to tongyou server, manages screen replicas.
        .target(
            name: "TYClient",
            dependencies: ["TYTerminal", "TYProtocol", "TYServer"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // tongyou executable: unified CLI for daemon and session management.
        .executableTarget(
            name: "tongyou",
            dependencies: ["TYClient", "TYProtocol", "TYServer"],
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

        .testTarget(
            name: "TYClientTests",
            dependencies: ["TYClient", "TYServer", "TYProtocol", "TYTerminal"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .testTarget(
            name: "TYPTYTests",
            dependencies: ["TYPTY", "TYTerminal"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .executableTarget(
            name: "acs-demo",
            dependencies: ["TYTerminal"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
