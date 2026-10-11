import AeroCore
import Foundation

/// Where SSHKit finds its executables and runtime files.
///
/// The app uses ``standard``: `/usr/bin/ssh`, `/usr/bin/ssh-keyscan` and the `~/.aeroops/` paths
/// from `AeroPaths`. Tests inject a temporary `AeroPaths` and, for the runner, a fake `ssh`
/// executable (any script that accepts ssh's argument vector).
public struct SSHContext: Sendable, Hashable {
    /// Runtime paths: generated config, known_hosts, agent socket, ControlMaster directory.
    public var paths: AeroPaths
    /// The OpenSSH client. Always `/usr/bin/ssh` in the app.
    public var sshExecutable: URL
    /// `ssh-keyscan`, used for the first-contact host-key fetch.
    public var keyscanExecutable: URL

    /// The system OpenSSH client.
    public static let systemSSH = URL(filePath: "/usr/bin/ssh")
    /// The system `ssh-keyscan`.
    public static let systemKeyscan = URL(filePath: "/usr/bin/ssh-keyscan")
    /// The app's real paths and the system executables.
    public static let standard = SSHContext()

    public init(
        paths: AeroPaths = .standard,
        sshExecutable: URL = SSHContext.systemSSH,
        keyscanExecutable: URL = SSHContext.systemKeyscan
    ) {
        self.paths = paths
        self.sshExecutable = sshExecutable
        self.keyscanExecutable = keyscanExecutable
    }

    /// `~/.aeroops/ssh_config`.
    public var configFile: URL { paths.sshConfig }
    /// `~/.aeroops/agent.sock`, exported to every `ssh` as `SSH_AUTH_SOCK`.
    public var agentSocket: URL { paths.agentSocket }
    /// `~/.aeroops/known_hosts`.
    public var knownHostsFile: URL { paths.knownHosts }
    /// `~/.aeroops/cm/`.
    public var controlMasterDirectory: URL { paths.controlMasterDirectory }

    /// Environment variables every spawned `ssh` gets on top of the inherited environment.
    ///
    /// The generated config also sets `IdentityAgent`, which takes precedence; `SSH_AUTH_SOCK`
    /// covers anything that ignores the config (and nested `ssh` started by ProxyJump).
    public var environmentOverrides: [String: String] {
        ["SSH_AUTH_SOCK": agentSocket.filePath]
    }

    /// The command a terminal tab runs for `host`: `/usr/bin/ssh -F <config> aero-<id>`.
    ///
    /// Interactive, so no `BatchMode`: the user can answer prompts in the terminal.
    /// TerminalKit applies ``SSHCommandLine/environment`` on top of the tab's environment.
    public func terminalCommand(for host: RemoteHost) -> SSHCommandLine {
        SSHCommandLine(
            executable: sshExecutable,
            arguments: ["-F", configFile.filePath, host.sshAlias],
            environment: environmentOverrides
        )
    }
}

/// A fully resolved process invocation.
public struct SSHCommandLine: Sendable, Hashable {
    /// The program to run.
    public var executable: URL
    /// Arguments after `argv[0]`.
    public var arguments: [String]
    /// Variables to set on top of the inherited environment.
    public var environment: [String: String]

    public init(executable: URL, arguments: [String], environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }

    /// `argv`, including `argv[0]` (the executable path).
    public var argv: [String] { [executable.filePath] + arguments }
}

extension RemoteHost {
    /// The host's alias in the generated ssh_config: `aero-<id>`, lower case.
    ///
    /// Lower case matters: ssh matches `Host` patterns case-sensitively against the alias given
    /// on the command line, so the config and every caller must agree on one spelling.
    public var sshAlias: String { "aero-" + id.uuidString.lowercased() }

    /// The name ssh looks up in known_hosts: `address` for port 22, otherwise `[address]:port`.
    ///
    /// ssh lower-cases `HostName` before the lookup (verified against OpenSSH 10.3), so this does too.
    public var knownHostsName: String {
        KnownHostsFile.hostName(address: address, port: port)
    }
}

extension URL {
    /// The file-system path without percent encoding.
    var filePath: String { path(percentEncoded: false) }
}
