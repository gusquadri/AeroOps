import Foundation

/// Runtime file locations.
///
/// Unix socket paths on macOS are capped at 104 bytes, so sockets live under the short
/// `~/.aeroops/` directory. Use ``standard`` in the app and a temporary root in tests.
public struct AeroPaths: Sendable, Hashable {
    /// `~/.aeroops/`: sockets, generated ssh_config, the copy of the pinned host keys, public keys.
    public var dotDirectory: URL

    /// Paths rooted at `home`, by default the real home directory on macOS (the app is not
    /// sandboxed). iOS denies writes to its home, the app container's root, so the iOS app passes
    /// a directory of its own to ``init(dotDirectory:)``.
    public init(home: URL = URL.homeDirectory) {
        dotDirectory = home.appending(path: ".aeroops", directoryHint: .isDirectory)
    }

    /// Paths with an explicit root: the iOS app's, and tests'.
    public init(dotDirectory: URL) {
        self.dotDirectory = dotDirectory
    }

    /// The Mac user's real paths.
    public static let standard = AeroPaths()

    /// `~/.aeroops/agent.sock`: the in-app ssh-agent.
    public var agentSocket: URL { dotDirectory.appending(path: "agent.sock") }
    /// `~/.aeroops/bridge.sock`: the MCP bridge.
    public var bridgeSocket: URL { dotDirectory.appending(path: "bridge.sock") }
    /// `~/.aeroops/askpass.sock`: hands password hosts' passwords to `aeroops-askpass`.
    public var askpassSocket: URL { dotDirectory.appending(path: "askpass.sock") }
    /// `~/.aeroops/cm/`: ControlMaster sockets, named by a hash of each host's connection settings.
    public var controlMasterDirectory: URL { dotDirectory.appending(path: "cm", directoryHint: .isDirectory) }
    /// `~/.aeroops/ssh_config`: generated, one block per host.
    public var sshConfig: URL { dotDirectory.appending(path: "ssh_config") }
    /// `~/.aeroops/synced_known_hosts`: ssh's copy of the host keys pinned in the Keychain.
    public var knownHosts: URL { dotDirectory.appending(path: "synced_known_hosts") }
    /// `~/.aeroops/pub/`: public keys referenced by `IdentityFile`.
    public var publicKeysDirectory: URL { dotDirectory.appending(path: "pub", directoryHint: .isDirectory) }
}
