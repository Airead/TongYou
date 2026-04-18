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
        .library(name: "TYConfig", targets: ["TYConfig"]),
        .library(name: "TYServer", targets: ["TYServer"]),
        .library(name: "TYClient", targets: ["TYClient"]),
        .library(name: "TYAutomation", targets: ["TYAutomation"]),
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

        // Configuration file parser (key = value format).
        .target(
            name: "TYConfig",
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
            dependencies: ["TYTerminal", "TYPTY", "TYProtocol", "TYShell", "TYConfig"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // GUI automation: JSON/line Unix-socket server used by the GUI app for
        // script-driven automation (`tongyou app ...`). Reuses TYProtocol's
        // socket primitives; independent of the binary daemon protocol.
        .target(
            name: "TYAutomation",
            dependencies: ["TYProtocol", "TYServer"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Client library: connects to tongyou server, manages screen replicas.
        .target(
            name: "TYClient",
            dependencies: ["TYTerminal", "TYProtocol", "TYServer", "TYAutomation"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // tongyou executable: unified CLI for daemon and session management.
        .executableTarget(
            name: "tongyou",
            dependencies: ["TYClient", "TYProtocol", "TYServer", "TYAutomation"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .testTarget(
            name: "TYTerminalTests",
            dependencies: ["TYTerminal"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .testTarget(
            name: "TYConfigTests",
            dependencies: ["TYConfig"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .testTarget(
            name: "TYProtocolTests",
            dependencies: ["TYProtocol", "TYTerminal"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .testTarget(
            name: "TYServerTests",
            dependencies: ["TYServer", "TYProtocol", "TYTerminal", "TYConfig"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .testTarget(
            name: "TYClientTests",
            dependencies: ["TYClient", "TYServer", "TYProtocol", "TYTerminal"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .testTarget(
            name: "TYAutomationTests",
            dependencies: ["TYAutomation", "TYProtocol"],
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

        .executableTarget(
            name: "DirtyRegionValidator",
            dependencies: ["TYTerminal"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
