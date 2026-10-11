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
        .library(name: "AeroTheme", targets: ["AeroTheme"]),
    ],
    dependencies: [
        // Phase 4 adds the libghostty wrapper
        // (pinned to an exact version) and wires it into TerminalKit below.
    ],
    targets: [
        // Models, parsers, ShellQuote, HostStore, runtime paths. Depends on nothing.
        .target(name: "AeroCore"),

        // System /usr/bin/ssh via Process, generated ssh_config, ControlMaster, host-key TOFU.
        .target(name: "SSHKit", dependencies: ["AeroCore"]),

        // In-app ssh-agent: Unix socket protocol, Keychain / Secure Enclave key store, signing.
        .target(name: "KeyAgent", dependencies: ["AeroCore"]),

        // Metrics script + parser, Docker, Kubernetes, one polling actor per host.
        .target(name: "Collectors", dependencies: ["SSHKit", "AeroCore"]),

        // libghostty surface wrapper and tab model.
        // Phase 4: add the GhosttyKit product here, e.g. .product(name: "GhosttyKit", package: "...").
        .target(name: "TerminalKit", dependencies: ["SSHKit"]),

        // bridge.sock server for aeroops-mcp, PolicyEngine, ApprovalCenter, AuditLog.
        .target(name: "AgentBridge", dependencies: ["Collectors", "SSHKit", "AeroCore"]),

        // Frutiger Aero design tokens and glossy components. Must NOT depend on AeroCore.
        .target(name: "AeroTheme"),

        // Test-only helpers shared by every test target (fixture lookup in repo `dev/fixtures/`).
        // Not exported as a product, so it never ships in the app.
        .target(name: "AeroTestSupport", path: "Tests/AeroTestSupport"),

        .testTarget(name: "AeroCoreTests", dependencies: ["AeroCore", "AeroTestSupport"]),
        .testTarget(name: "SSHKitTests", dependencies: ["SSHKit", "AeroTestSupport"]),
        .testTarget(name: "KeyAgentTests", dependencies: ["KeyAgent", "AeroTestSupport"]),
        .testTarget(name: "CollectorsTests", dependencies: ["Collectors", "AeroTestSupport"]),
        .testTarget(name: "AgentBridgeTests", dependencies: ["AgentBridge", "AeroTestSupport"]),
        .testTarget(name: "AeroThemeTests", dependencies: ["AeroTheme"]),
    ]
)
