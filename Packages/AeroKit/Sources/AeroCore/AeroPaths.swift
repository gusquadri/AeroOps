import Foundation

/// Runtime file locations.
///
/// Unix socket paths on macOS are capped at 104 bytes, so sockets live under the short
/// `~/.aeroops/` directory. Use ``standard`` in the app and a temporary root in tests.
public struct AeroPaths: Sendable, Hashable {
    /// `~/.aeroops/`: sockets, generated ssh_config, the copy of the pinned host keys, public keys.
    public var dotDirectory: URL
    /// `~/Library/Application Support/AeroOps/`: where an older AeroOps kept `hosts.json`.
    public var applicationSupport: URL

    /// Paths rooted at `home`: the real home directory on macOS (the app is not sandboxed), the
    /// app container on iOS.
    public init(home: URL = URL.homeDirectory) {
        dotDirectory = home.appending(path: ".aeroops", directoryHint: .isDirectory)
        applicationSupport = home.appending(path: "Library/Application Support/AeroOps", directoryHint: .isDirectory)
    }

    /// Paths with explicit roots, for tests.
    public init(dotDirectory: URL, applicationSupport: URL) {
        self.dotDirectory = dotDirectory
        self.applicationSupport = applicationSupport
    }

    /// The current user's real paths.
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
    /// `~/.aeroops/known_hosts`: where an older AeroOps pinned host keys.
    public var legacyKnownHosts: URL { dotDirectory.appending(path: "known_hosts") }
    /// `~/.aeroops/pub/`: public keys referenced by `IdentityFile`.
    public var publicKeysDirectory: URL { dotDirectory.appending(path: "pub", directoryHint: .isDirectory) }
    /// `~/Library/Application Support/AeroOps/hosts.json`: where an older AeroOps kept the hosts.
    public var legacyHostsFile: URL { applicationSupport.appending(path: HostStore.legacyFileName) }
}
