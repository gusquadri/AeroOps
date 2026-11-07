import AeroCore
import Foundation
import KeyAgent
import SSHKit

/// Test connection through SSHKit: `ssh -F <probe config> -o BatchMode=yes aero-<id> uname -sr`
/// via the in-app agent (or the system agent when the fallback is on). Password hosts run without
/// `BatchMode` and get the password from `aeroops-askpass`.
struct SSHConnectionTester: ConnectionTester {
    let services: SSHServices

    func testConnection(to host: RemoteHost, password: String?) async -> ConnectionTestResult {
        await services.testConnection(to: host, password: password)
    }
}

extension SSHServices {
    /// What Test connection runs on the server.
    static let testCommand = "uname -sr"
    /// Generous: covers a Touch ID prompt for keys that need one.
    static let testTimeout: Duration = .seconds(45)

    /// Tests `host`, which may be an unsaved draft.
    ///
    /// 1. The draft must render into `ssh_config`. A key host in in-app mode needs a key and a
    ///    running agent; a password host needs the askpass server and a password (`password`, or
    ///    the saved one).
    /// 2. Blocked hosts are never contacted.
    /// 3. First contact (nothing pinned): `ssh-keyscan`, then ``ConnectionTestResult/Outcome/hostKeyUnknown(offered:)``
    ///    so the user can trust the key. No login is attempted before that.
    /// 4. Otherwise one `ssh` run against a throwaway config that holds only this host, with
    ///    connection sharing off, so the result reflects this draft and not an open master.
    ///    A typed `password` reaches `aeroops-askpass` through a one-time token and is never saved.
    ///    A test of the saved password opens or closes the ``PasswordAttemptGate`` for the host.
    ///
    /// No retries: OpenSSH 9.8+ penalises addresses that keep failing authentication, and every
    /// wrong password counts towards the account's lockout.
    func testConnection(to host: RemoteHost, password: String? = nil) async -> ConnectionTestResult {
        let clock = ContinuousClock()
        let start = clock.now
        func result(
            _ outcome: ConnectionTestResult.Outcome,
            _ message: String,
            hint: String? = nil,
            keyToAuthorize: UUID? = nil
        ) -> ConnectionTestResult {
            ConnectionTestResult(
                outcome: outcome, message: message, elapsed: start.duration(to: clock.now),
                hint: hint, keyToAuthorize: keyToAuthorize
            )
        }

        let context = self.context
        do {
            try SSHConfigWriter(context: context).validate(host)
        } catch {
            return result(.failure, error.localizedDescription)
        }

        var key: SSHKeyRecord?
        if host.auth == .password {
            guard context.askpass != nil else {
                return result(
                    .failure,
                    "AeroOps can’t hand passwords to ssh: \(askpassError ?? "the askpass server is not running.")",
                    hint: "Terminal tabs still work: they ask for the password."
                )
            }
            guard password != nil || passwords.hasPassword(for: host.id) else {
                return result(.failure, "Enter the password first.")
            }
        } else if context.agent == .inApp {
            guard host.keyId != nil else {
                return result(.failure, "Choose a key for this host first.", hint: "Generate or import one in Settings › Keys.")
            }
            guard let found = self.key(for: host) else {
                return result(.failure, "The selected key no longer exists.", hint: "Choose another key above.")
            }
            key = found
            switch agentStatus {
            case .running: break
            case .failed(let reason): return result(.failure, "The AeroOps agent is not running: \(reason)")
            case .stopped, .usingSystemAgent: return result(.failure, "The AeroOps agent is not running.")
            }
        }

        if let block = await hostKeys.block(for: host) {
            await refreshHostKeyBlocks()
            return result(.hostKeyChanged(block), Self.changedMessage(host))
        }
        do {
            if try await hostKeys.pinnedKeys(for: host).isEmpty {
                switch try await hostKeys.verify(host) {
                case .unknown(let offered):
                    return result(
                        .hostKeyUnknown(offered: offered),
                        "First connection to \(host.address): check the host key before trusting it."
                    )
                case .changed:
                    await refreshHostKeyBlocks()
                    if let block = await hostKeys.block(for: host) {
                        return result(.hostKeyChanged(block), Self.changedMessage(host))
                    }
                    return result(.failure, Self.changedMessage(host))
                case .trusted:
                    break
                }
            }
        } catch is CancellationError {
            return result(.failure, "Test cancelled.")
        } catch let error as SSHError {
            let (message, hint) = Self.describe(error, host: host)
            return result(.failure, message, hint: hint)
        } catch {
            return result(.failure, error.localizedDescription)
        }

        let probe: URL
        do {
            probe = try writeProbeConfig(for: host, context: context)
        } catch {
            return result(.failure, error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: probe) }
        var probeContext = context
        probeContext.configFileOverride = probe
        var token: String?
        if host.auth == .password, let password {
            do {
                token = try passwords.beginTemporary(password, for: host.id)
            } catch {
                return result(.failure, error.localizedDescription)
            }
            probeContext.askpassToken = token
        }
        defer { if let token { passwords.endTemporary(token) } }
        let testsSavedPassword = host.auth == .password && token == nil

        let outcome: SSHResult
        do {
            outcome = try await SSHRunner(context: probeContext, hostKeys: hostKeys)
                .run(Self.testCommand, on: host, timeout: Self.testTimeout)
        } catch is CancellationError {
            return result(.failure, "Test cancelled.")
        } catch {
            await refreshHostKeyBlocks()
            let (message, hint) = Self.describe(error, host: host)
            return result(.failure, message, hint: hint)
        }

        if let transportError = outcome.transportError {
            if transportError == .hostKeyChanged {
                _ = try? await hostKeys.verify(host)
                await refreshHostKeyBlocks()
                if let block = await hostKeys.block(for: host) {
                    return result(.hostKeyChanged(block), Self.changedMessage(host))
                }
            }
            if host.auth == .password, transportError == .authFailed {
                if testsSavedPassword { await passwordGate.reject(host.id) }
                let (message, hint) = Self.describePasswordFailure(stderr: outcome.stderrString, host: host)
                return result(.failure, message, hint: hint)
            }
            let (message, hint) = Self.describe(transportError, host: host)
            return result(.failure, message, hint: hint, keyToAuthorize: transportError == .authFailed ? key?.id : nil)
        }
        if testsSavedPassword {
            await passwordGate.reset(host.id)
            await passwordGate.accept(host.id)
            passwordsDidChange?(host.id)
        }
        if outcome.exitCode != 0 {
            let stderr = outcome.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            return result(.failure, "Logged in, but `\(Self.testCommand)` exited with status \(outcome.exitCode)." + (stderr.isEmpty ? "" : " \(stderr)"))
        }
        let system = outcome.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let via = switch host.auth {
        case .password: token == nil ? " with the saved password" : " with the password above"
        case .key: context.agent == .inApp ? (key.map { " with “\($0.name)”" } ?? "") : " via the system ssh-agent"
        }
        return result(
            .success,
            "Connected as \(host.user)@\(host.address):\(host.port)\(via)" + (system.isEmpty ? "." : " · \(system)"),
            hint: token == nil ? nil : "Save the host to keep the password in the Keychain."
        )
    }

    /// Writes `probe-<random>` (0600) next to `ssh_config`: a block that turns connection
    /// sharing off for the host, then the host's normal block (ssh_config is first-match-wins).
    private func writeProbeConfig(for host: RemoteHost, context: SSHContext) throws -> URL {
        let writer = SSHConfigWriter(context: context)
        let rendering = try writer.render([host])
        if let rejection = rendering.rejected[host.id] { throw rejection }
        try writer.prepareDirectories()
        let text = """
            Host \(host.sshAlias)
              ControlMaster no
              ControlPath none

            """ + rendering.text
        let url = paths.dotDirectory.appending(path: "probe-\(UUID().uuidString.prefix(8).lowercased())")
        guard FileManager.default.createFile(
            atPath: url.path(percentEncoded: false),
            contents: Data(text.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw SSHConfigError.fileSystem("could not create \(url.lastPathComponent)")
        }
        return url
    }

    static func changedMessage(_ host: RemoteHost) -> String {
        "The host key of \(host.address) has changed. AeroOps blocks this host until you review the new key."
    }

    /// A friendly message and an optional hint for each SSH failure.
    static func describe(_ error: any Error, host: RemoteHost) -> (message: String, hint: String?) {
        guard let error = error as? SSHError else { return (error.localizedDescription, nil) }
        let target = "\(host.address):\(host.port)"
        switch error {
        case .authFailed where host.auth == .password:
            return ("\(host.user)@\(target) rejected the password.", passwordHint)
        case .authFailed:
            return (
                "\(host.user)@\(target) rejected the key.",
                "Add the key's authorized_keys line to ~\(host.user)/.ssh/authorized_keys on the server, then test again. AeroOps does not retry: repeated failures can get this Mac temporarily banned by the server."
            )
        case .connectionRefused:
            return ("\(target) refused the connection.", "Check the port and that sshd is running.")
        case .timeout:
            return ("Timed out connecting to \(target).", "Check the address, VPN and firewall.")
        case .nameResolutionFailed:
            return ("“\(host.address)” could not be resolved.", "Check the spelling, or use an IP address.")
        case .hostUnreachable:
            return ("\(host.address) is unreachable.", "Check the network route or VPN.")
        case .connectionClosed:
            return (
                "\(target) closed the connection before login.",
                "The server may be limiting connections (MaxStartups or PerSourcePenalties). Wait a minute before testing again."
            )
        case .hostKeyChanged:
            return (changedMessage(host), nil)
        case .hostKeyUnknown:
            return ("The host key of \(host.address) is not trusted yet.", "Test again to review and trust it.")
        case .launchFailed, .remoteCommandFailed, .invalidRequest, .other:
            return (error.localizedDescription, nil)
        }
    }

    static let passwordHint = "Check the password, then test again. AeroOps does not retry: repeated failures can lock the account or get this Mac temporarily banned by the server."

    /// Why a password login failed, from ssh's stderr: the server takes no passwords, the
    /// askpass helper gave none (its `aeroops-askpass:` line), or the password was wrong.
    static func describePasswordFailure(stderr: String, host: RemoteHost) -> (message: String, hint: String?) {
        let target = "\(host.address):\(host.port)"
        if let methods = deniedMethods(stderr), !methods.contains("password"), !methods.contains("keyboard-interactive") {
            return (
                "\(target) does not accept passwords for \(host.user) (it allows: \(methods.joined(separator: ", "))).",
                "Turn on PasswordAuthentication or KbdInteractiveAuthentication in the server’s sshd_config, or sign in with a key."
            )
        }
        let refusal = stderr.split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix(SSHError.askpassMarker) }
            .map { String($0.dropFirst(SSHError.askpassMarker.count)).trimmingCharacters(in: .whitespaces) }
        if let refusal, refusal != AskpassRefusal.alreadyAnswered.description {
            return ("No password was sent to \(target): \(refusal).", nil)
        }
        return ("\(host.user)@\(target) rejected the password.", passwordHint)
    }

    /// The methods in ssh's final `Permission denied (publickey,password).` line, if any.
    static func deniedMethods(_ stderr: String) -> [String]? {
        guard let line = stderr.split(whereSeparator: \.isNewline).last(where: { $0.contains("Permission denied (") }),
              let open = line.range(of: "Permission denied ("),
              let close = line[open.upperBound...].firstIndex(of: ")")
        else { return nil }
        return line[open.upperBound..<close].split(separator: ",").map(String.init)
    }
}
