// swift-tools-version: 6.2
// AeroKit: every non-UI module of AeroOps, one target per module.
// Swift 6 language mode (the default for tools-version 6.x) gives complete strict concurrency checking.

import PackageDescription

let package = Package(
    name: "AeroKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "AeroCore", targets: ["AeroCore"]),
        .library(name: "SSHKit", targets: ["SSHKit"]),
        .library(name: "KeyAgent", targets: ["KeyAgent"]),
        .library(name: "Collectors", targets: ["Collectors"]),
        .library(name: "TerminalKit", targets: ["TerminalKit"]),
        .library(name: "AgentBridge", targets: ["AgentBridge"]),
        // Shared by the app (through AgentBridge) and the `aeroops-mcp` CLI (project.yml).
        .library(name: "BridgeProtocol", targets: ["BridgeProtocol"]),
        // Shared by the app (through SSHKit and KeyAgent) and the `aeroops-askpass` helper.
        .library(name: "AskpassProtocol", targets: ["AskpassProtocol"]),
        .library(name: "AeroTheme", targets: ["AeroTheme"]),
    ],
    dependencies: [
        // libghostty wrapper, pinned exactly.
        // Only TerminalKit links it; the app gets it transitively through the TerminalKit product.
        .package(url: "https://github.com/Lakr233/libghostty-spm", exact: "2.2.2026101003"),
    ],
    targets: [
        // Models, parsers, ShellQuote, HostStore, runtime paths. Depends on nothing.
        .target(name: "AeroCore"),

        // System /usr/bin/ssh via Process, generated ssh_config, ControlMaster, host-key TOFU.
        .target(name: "SSHKit", dependencies: ["AeroCore", "AskpassProtocol"]),

        // In-app ssh-agent: Unix socket protocol, Keychain / Secure Enclave key store, signing.
        // Also the askpass server that hands password hosts' passwords to `aeroops-askpass`.
        .target(name: "KeyAgent", dependencies: ["AeroCore", "AskpassProtocol"]),

        // The askpass.sock contract between the app and `aeroops-askpass`, the SSH_ASKPASS
        // helper for password hosts. Linked by the helper,
        // so it depends on nothing.
        .target(name: "AskpassProtocol"),

        // Metrics script + parser, Docker, Kubernetes, one polling actor per host.
        .target(name: "Collectors", dependencies: ["SSHKit", "AeroCore"]),

        // libghostty surface wrapper and tab model. Takes a generic launch spec (executable +
        // arguments), so it does not depend on SSHKit; the app builds the ssh command line.
        .target(
            name: "TerminalKit",
            dependencies: ["AeroCore", .product(name: "GhosttyTerminal", package: "libghostty-spm")]
        ),

        // Interactive self-test for TerminalKit against the dev SSH container (needs a window
        // server). Not a product, so it never ships in the app. Run via
        // Tests/TerminalKitSelfTest/run-selftest.sh.
        .executableTarget(
            name: "TerminalKitSelfTest",
            dependencies: ["TerminalKit", .product(name: "GhosttyTerminal", package: "libghostty-spm")],
            path: "Tests/TerminalKitSelfTest",
            exclude: ["run-selftest.sh"]
        ),

        // The bridge.sock contract between the app and `aeroops-mcp`: JSON-lines messages, line
        // framing, the static tool catalog, argument validation and the socket path rule.
        // Linked by the CLI, so it stays small: AeroCore only.
        .target(name: "BridgeProtocol", dependencies: ["AeroCore"]),

        // bridge.sock server for aeroops-mcp, peer code-signature check, PolicyEngine,
        // ApprovalCenter, run_command executor, AuditLog. The app supplies the read tools'
        // data through `BridgeToolHandler`, so this module does not depend on Collectors.
        .target(name: "AgentBridge", dependencies: ["BridgeProtocol", "SSHKit", "AeroCore"]),

        // Test-only harness: a Bridge with fake hosts on a temporary socket, for driving the real
        // `aeroops-mcp` end to end (MCP Inspector, `claude -p`). Not a product, never shipped.
        // Usage: the header comment of Tests/BridgeHarness/main.swift.
        .executableTarget(
            name: "BridgeHarness",
            dependencies: ["AgentBridge", "BridgeProtocol", "AeroCore"],
            path: "Tests/BridgeHarness"
        ),

        // Frutiger Aero design tokens and glossy components. Must NOT depend on AeroCore.
        .target(name: "AeroTheme"),

        // Test-only helpers shared by every test target (fixture lookup in repo `dev/fixtures/`).
        // Not exported as a product, so it never ships in the app.
        .target(name: "AeroTestSupport", path: "Tests/AeroTestSupport"),

        .testTarget(name: "AeroCoreTests", dependencies: ["AeroCore", "AeroTestSupport"]),
        .testTarget(name: "SSHKitTests", dependencies: ["SSHKit", "AskpassProtocol", "AeroTestSupport"]),
        .testTarget(name: "KeyAgentTests", dependencies: ["KeyAgent", "AskpassProtocol", "AeroTestSupport"]),
        .testTarget(name: "AskpassProtocolTests", dependencies: ["AskpassProtocol"]),
        .testTarget(name: "CollectorsTests", dependencies: ["Collectors", "AeroTestSupport"]),
        .testTarget(name: "TerminalKitTests", dependencies: ["TerminalKit", "AeroCore"]),
        .testTarget(name: "BridgeProtocolTests", dependencies: ["BridgeProtocol", "AeroCore"]),
        .testTarget(name: "AgentBridgeTests", dependencies: ["AgentBridge", "BridgeProtocol", "AeroCore", "SSHKit", "AeroTestSupport"]),
        .testTarget(name: "AeroThemeTests", dependencies: ["AeroTheme"]),
    ]
)
