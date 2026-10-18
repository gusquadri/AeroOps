// swift-tools-version: 6.2
// AeroKit: every non-UI module of AeroOps, one target per module.
// Swift 6 language mode (the default for tools-version 6.x) gives complete strict concurrency checking.

import PackageDescription

let package = Package(
    name: "AeroKit",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "AeroCore", targets: ["AeroCore"]),
        .library(name: "SSHKit", targets: ["SSHKit"]),
        .library(name: "KeyAgent", targets: ["KeyAgent"]),
        .library(name: "Collectors", targets: ["Collectors"]),
        .library(name: "EmbeddedSSH", targets: ["EmbeddedSSH"]),
        .library(name: "EmbeddedTerminal", targets: ["EmbeddedTerminal"]),
        .library(name: "TerminalKit", targets: ["TerminalKit"]),
        .library(name: "AgentBridge", targets: ["AgentBridge"]),
        // Shared by the app (through AgentBridge) and the `aeroops-mcp` CLI (project.yml).
        .library(name: "BridgeProtocol", targets: ["BridgeProtocol"]),
        // Shared by the app (through SSHKit and KeyAgent) and the `aeroops-askpass` helper.
        .library(name: "AskpassProtocol", targets: ["AskpassProtocol"]),
        .library(name: "AeroTheme", targets: ["AeroTheme"]),
    ],
    dependencies: [
        // libghostty wrapper, pinned exactly. Linked by TerminalStyle, TerminalKit and
        // EmbeddedTerminal; the apps get it transitively through the TerminalKit product (Mac) and
        // the EmbeddedTerminal product (iOS).
        .package(url: "https://github.com/Lakr233/libghostty-spm", exact: "2.2.2026101003"),
        // SSH in Swift for iOS, which has no /usr/bin/ssh. Pinned exactly. Only EmbeddedSSH links it.
        .package(url: "https://github.com/apple/swift-nio-ssh", exact: "0.15.0"),
        // swift-nio-ssh's own dependency; declared for the NIOCore/NIOPosix products.
        .package(url: "https://github.com/apple/swift-nio", from: "2.81.0"),
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

        // In-process SSH client for iOS (swift-nio-ssh): the same `HostCommandRunning` /
        // `HostCommandStreaming` the collectors use with SSHRunner, host keys pinned in SSHKit's
        // HostKeyStore, keys from KeyAgent's KeyStore, passwords from its HostPasswordVault.
        // Also long-lived sessions: terminals (pty + shell) and subsystems, which SSHKit's
        // SFTPClient runs over as a `RemoteByteChannel`.
        .target(
            name: "EmbeddedSSH",
            dependencies: [
                "SSHKit", "KeyAgent", "Collectors", "AeroCore",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),

        // The terminal look both apps share: TerminalAppearance (font, colours) and the
        // libghostty settings and key bindings built from it. No AppKit or UIKit.
        .target(
            name: "TerminalStyle",
            dependencies: [.product(name: "GhosttyTerminal", package: "libghostty-spm")]
        ),

        // libghostty surface wrapper and tab model. Takes a generic launch spec (executable +
        // arguments), so it does not depend on SSHKit; the app builds the ssh command line.
        // Mac only (AppKit, forkpty).
        .target(
            name: "TerminalKit",
            dependencies: ["AeroCore", "CTerminalPTY", "TerminalStyle", .product(name: "GhosttyTerminal", package: "libghostty-spm")]
        ),

        // The iOS terminal: a libghostty surface over an EmbeddedSSH terminal channel (keys,
        // window size and output bridged through an in-memory session). Never linked by the Mac
        // app, which runs terminals through TerminalKit and /usr/bin/ssh.
        .target(
            name: "EmbeddedTerminal",
            dependencies: [
                "EmbeddedSSH", "SSHKit", "AeroCore", "TerminalStyle",
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            ]
        ),

        // Pseudo-terminal spawn for TerminalKit (fork + exec needs C: Swift cannot call
        // `fork` safely or the variadic `ioctl`).
        .target(name: "CTerminalPTY"),

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
        // run_command executor. The app supplies the read tools'
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
        // Logos/: the system logo SVGs for StatusBubble (Simple Icons, CC0).
        .target(name: "AeroTheme", resources: [.copy("Logos")]),

        // Test-only helpers shared by every test target (fixture lookup in repo `dev/fixtures/`).
        // Not exported as a product, so it never ships in the app.
        .target(name: "AeroTestSupport", path: "Tests/AeroTestSupport"),

        .testTarget(name: "AeroCoreTests", dependencies: ["AeroCore", "AeroTestSupport"]),
        .testTarget(name: "SSHKitTests", dependencies: ["SSHKit", "AskpassProtocol", "AeroTestSupport"]),
        .testTarget(name: "KeyAgentTests", dependencies: ["KeyAgent", "AskpassProtocol", "AeroTestSupport"]),
        .testTarget(name: "AskpassProtocolTests", dependencies: ["AskpassProtocol"]),
        .testTarget(name: "CollectorsTests", dependencies: ["Collectors", "AeroTestSupport"]),
        .testTarget(
            name: "EmbeddedSSHTests",
            dependencies: [
                "EmbeddedSSH", "EmbeddedTerminal", "SSHKit", "KeyAgent", "Collectors", "AeroCore", "AeroTestSupport",
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "TerminalKitTests",
            dependencies: ["TerminalKit", "TerminalStyle", "AeroCore", .product(name: "GhosttyTerminal", package: "libghostty-spm")]
        ),
        .testTarget(name: "BridgeProtocolTests", dependencies: ["BridgeProtocol", "AeroCore"]),
        .testTarget(name: "AgentBridgeTests", dependencies: ["AgentBridge", "BridgeProtocol", "AeroCore", "SSHKit", "AeroTestSupport"]),
        .testTarget(name: "AeroThemeTests", dependencies: ["AeroTheme"]),
    ]
)
