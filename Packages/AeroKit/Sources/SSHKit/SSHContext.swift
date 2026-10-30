import AeroCore
import AskpassProtocol
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
    /// Which ssh-agent signs for hosts. ``AgentChoice/inApp`` unless the user turned on the
    /// "Use system ssh-agent instead" fallback in Settings.
    public var agent: AgentChoice

    /// The agent ssh talks to.
    public enum AgentChoice: String, Sendable, Hashable, Codable, CaseIterable {
        /// KeyAgent on `~/.aeroops/agent.sock`, with the app's Keychain and Secure Enclave keys.
        case inApp
        /// Whatever `SSH_AUTH_SOCK` the app inherited (launchd's agent on macOS). A fallback for
        /// in-app agent bugs. The app's own keys are not in that
        /// agent, so ssh offers whatever keys it holds.
        case system
    }

    /// The system OpenSSH client.
    public static let systemSSH = URL(filePath: "/usr/bin/ssh")
    /// The system `ssh-keyscan`.
    public static let systemKeyscan = URL(filePath: "/usr/bin/ssh-keyscan")
    /// The app's real paths and the system executables.
    public static let standard = SSHContext()

    public init(
        paths: AeroPaths = .standard,
        sshExecutable: URL = SSHContext.systemSSH,
        keyscanExecutable: URL = SSHContext.systemKeyscan,
        agent: AgentChoice = .inApp
    ) {
        self.paths = paths
        self.sshExecutable = sshExecutable
        self.keyscanExecutable = keyscanExecutable
        self.agent = agent
    }

    /// A different config file for one-off runs, e.g. testing an unsaved host draft against a
    /// throwaway config. `nil` (the default) means ``AeroPaths/sshConfig``.
    public var configFileOverride: URL?

    /// How ssh gets password hosts' passwords: the `aeroops-askpass` helper and the app's askpass
    /// socket. `nil` when the app has no askpass server (tests, previews) or the helper is missing
    /// from the bundle; background ssh for password hosts then keeps `BatchMode=yes` and fails
    /// authentication instead of prompting.
    public var askpass: AskpassRoute?
    /// A one-time token the askpass server maps to a password that is not saved yet (Test
    /// Connection on an unsaved draft). Passed to the helper as `AEROOPS_ASKPASS_TOKEN`.
    public var askpassToken: String?

    /// `~/.aeroops/ssh_config`, unless ``configFileOverride`` is set.
    public var configFile: URL { configFileOverride ?? paths.sshConfig }
    /// `~/.aeroops/agent.sock`, exported to every `ssh` as `SSH_AUTH_SOCK`.
    public var agentSocket: URL { paths.agentSocket }
    /// `~/.aeroops/synced_known_hosts`, the copy of ``HostKeyStore``'s pins ssh reads.
    public var knownHostsFile: URL { paths.knownHosts }

    /// What an older AeroOps's known_hosts left for ssh alone; see ``HostKeyStore/importLegacyPins(from:)``.
    public var legacyKnownHostsFile: URL { paths.legacyKnownHosts }
    /// `~/.aeroops/cm/`.
    public var controlMasterDirectory: URL { paths.controlMasterDirectory }

    /// Environment variables every spawned `ssh` gets on top of the inherited environment.
    ///
    /// The generated config also sets `IdentityAgent`, which takes precedence; `SSH_AUTH_SOCK`
    /// covers anything that ignores the config (and nested `ssh` started by ProxyJump).
    /// With ``AgentChoice/system`` nothing is overridden: ssh keeps the inherited `SSH_AUTH_SOCK`.
    public var environmentOverrides: [String: String] {
        switch agent {
        case .inApp: ["SSH_AUTH_SOCK": agentSocket.filePath]
        case .system: [:]
        }
    }

    /// Whether ssh can get `host`'s password without a terminal: a password host and an
    /// ``askpass`` route.
    public func usesAskpass(_ host: RemoteHost) -> Bool {
        host.auth == .password && askpass != nil
    }

    /// ``environmentOverrides`` plus, for a password host with an ``askpass`` route, the
    /// variables that make ssh ask `aeroops-askpass` for the password:
    ///
    /// - `SSH_ASKPASS` (the helper) and `SSH_ASKPASS_REQUIRE=force`, so ssh uses the helper even
    ///   without `DISPLAY` and even in a terminal tab.
    /// - `AEROOPS_ASKPASS_SOCKET`, `AEROOPS_ASKPASS_HOST` (the host id) and, with
    ///   ``askpassToken``, `AEROOPS_ASKPASS_TOKEN`. None of them is a secret.
    public func environment(for host: RemoteHost) -> [String: String] {
        var environment = environmentOverrides
        guard usesAskpass(host), let askpass else { return environment }
        environment["SSH_ASKPASS"] = askpass.helper.filePath
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment[Askpass.Environment.socket] = askpass.socket.filePath
        environment[Askpass.Environment.host] = host.id.uuidString
        if let askpassToken { environment[Askpass.Environment.token] = askpassToken }
        return environment
    }

    /// The command a terminal tab runs for `host`: `/usr/bin/ssh -F <config> aero-<id>`.
    ///
    /// Interactive, so no `BatchMode`: the user can answer prompts in the terminal.
    /// TerminalKit applies ``SSHCommandLine/environment`` on top of the tab's environment.
    /// A password host without an ``askpass`` route prompts in the tab, with ssh's usual three
    /// tries instead of the config's one.
    ///
    /// - Parameter sharesConnection: Run as a session on the host's ControlMaster (the default).
    ///   `false` adds `-o ControlPath=none`: the tab logs in on a connection of its own and takes
    ///   none of the master's sessions, which sshd caps (`MaxSessions`, 10 by default).
    public func terminalCommand(for host: RemoteHost, sharesConnection: Bool = true) -> SSHCommandLine {
        var arguments = ["-F", configFile.filePath]
        if !sharesConnection {
            arguments += ["-o", "ControlPath=none"]
        }
        if host.auth == .password, askpass == nil {
            arguments += ["-o", "NumberOfPasswordPrompts=3"]
        }
        return SSHCommandLine(
            executable: sshExecutable,
            arguments: arguments + [host.sshAlias],
            environment: environment(for: host)
        )
    }
}

/// Where ssh finds the askpass helper and the helper finds the app.
public struct AskpassRoute: Sendable, Hashable {
    /// `AeroOps.app/Contents/MacOS/aeroops-askpass`.
    public var helper: URL
    /// `~/.aeroops/askpass.sock`.
    public var socket: URL

    public init(helper: URL, socket: URL) {
        self.helper = helper
        self.socket = socket
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
