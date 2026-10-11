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
        // libghostty wrapper, pinned exactly.
        // Only TerminalKit links it; the app gets it transitively through the TerminalKit product.
        .package(url: "https://github.com/Lakr233/libghostty-spm", exact: "2.2.2026101003"),
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
        .testTarget(name: "TerminalKitTests", dependencies: ["TerminalKit", "AeroCore"]),
        .testTarget(name: "AgentBridgeTests", dependencies: ["AgentBridge", "AeroTestSupport"]),
        .testTarget(name: "AeroThemeTests", dependencies: ["AeroTheme"]),
    ]
)
