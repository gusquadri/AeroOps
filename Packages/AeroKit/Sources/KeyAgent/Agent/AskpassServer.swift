import AeroCore
import AskpassProtocol
import Darwin
import Foundation
import Security
import Synchronization

/// Hands password hosts' passwords to `aeroops-askpass` over `~/.aeroops/askpass.sock`.
///
/// One request per connection. Before answering, the server checks:
///
/// 1. the peer (``AskpassPeerValidator``): this user, the helper signed by the app's team, run
///    by `/usr/bin/ssh` that the app started;
/// 2. the prompt is the login password (``Askpass/isPasswordPrompt(_:kind:)``);
/// 3. this ssh process has not been answered before: a second prompt means the server rejected
///    the password, and answering again would only add a failed attempt;
/// 4. the vault has a password for the host (or the one-time token).
///
/// Every outcome is reported on ``events``; refusals carry a reason that is safe to show.
public final class AskpassServer: Sendable {
    public let socketURL: URL
    /// Answers and refusals. Buffers the newest 64 if nobody listens.
    public let events: AsyncStream<AskpassEvent>

    private let vault: HostPasswordVault
    private let validator: any AskpassPeerValidator
    private let listener: UnixSocketListener
    private let continuation: AsyncStream<AskpassEvent>.Continuation
    /// ssh processes already answered, so each gets at most one password.
    private let answered = Mutex<[pid_t: ContinuousClock.Instant]>([:])

    /// How long an answered ssh pid is remembered. ssh authenticates within seconds, and pids are
    /// not reused that fast.
    static let answeredMemory: Duration = .seconds(120)

    public init(
        socketURL: URL = AeroPaths.standard.askpassSocket,
        vault: HostPasswordVault,
        validator: any AskpassPeerValidator,
        maxConnections: Int = 16
    ) {
        self.socketURL = socketURL
        self.vault = vault
        self.validator = validator
        let (stream, continuation) = AsyncStream.makeStream(of: AskpassEvent.self, bufferingPolicy: .bufferingNewest(64))
        events = stream
        self.continuation = continuation
        listener = UnixSocketListener(
            socketPath: socketURL.path(percentEncoded: false), name: "askpass", maxConnections: maxConnections,
            readTimeoutSeconds: Askpass.timeoutSeconds, writeTimeoutSeconds: Askpass.timeoutSeconds)
    }

    deinit {
        listener.stop()
        continuation.finish()
    }

    public var isRunning: Bool { listener.isRunning }

    /// Creates the socket and starts answering. Does nothing if already running.
    public func start() throws(AgentServerError) {
        // An overflowing connection is closed unanswered; the helper then fails like any refusal.
        try listener.start(serve: { [weak self] fd, _ in self?.serve(fd) }, onOverflow: {})
    }

    /// Stops answering and removes the socket if it is still ours.
    public func stop() {
        listener.stop()
    }

    // MARK: Connections

    private func serve(_ fd: Int32) {
        let verdict = validator.validate(socket: fd)
        guard let line = AskpassWire.readLine(fd),
              let request = AskpassWire.decode(AskpassRequest.self, from: line),
              request.version == AskpassRequest.currentVersion else {
            refuse(fd, host: nil, viaToken: false, .malformedRequest)
            return
        }
        let viaToken = request.token != nil
        let sshPID: pid_t
        switch verdict {
        case .accepted(let pid):
            sshPID = pid
        case .rejected(let reason):
            refuse(fd, host: request.host, viaToken: viaToken, .untrustedPeer(reason))
            return
        }
        guard Askpass.isPasswordPrompt(request.prompt) else {
            refuse(fd, host: request.host, viaToken: viaToken, .notPasswordPrompt)
            return
        }
        guard claim(sshPID) else {
            refuse(fd, host: request.host, viaToken: viaToken, .alreadyAnswered)
            return
        }
        switch vault.answer(request) {
        case .success(let password):
            _ = AskpassWire.writeAll(fd, AskpassWire.line(AskpassReply.password(password)))
            continuation.yield(AskpassEvent(host: request.host, viaToken: viaToken, outcome: .answered))
        case .failure(let refusal):
            refuse(fd, host: request.host, viaToken: viaToken, refusal)
        }
    }

    /// Records `pid` as answered; `false` if it already was.
    private func claim(_ pid: pid_t) -> Bool {
        answered.withLock { answered in
            let now = ContinuousClock.now
            answered = answered.filter { now - $0.value < Self.answeredMemory }
            guard answered[pid] == nil else { return false }
            answered[pid] = now
            return true
        }
    }

    private func refuse(_ fd: Int32, host: UUID?, viaToken: Bool, _ refusal: AskpassRefusal) {
        _ = AskpassWire.writeAll(fd, AskpassWire.line(AskpassReply.refused(refusal.description)))
        continuation.yield(AskpassEvent(host: host, viaToken: viaToken, outcome: .refused(refusal)))
    }
}

/// What the askpass server did with one request.
public struct AskpassEvent: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case answered
        case refused(AskpassRefusal)
    }

    /// The host the helper asked about; `nil` when the request could not be read.
    public var host: UUID?
    /// The request used a one-time test token rather than the saved password.
    public var viaToken: Bool
    public var outcome: Outcome
}

// MARK: - Peer validation

/// The verdict on an askpass connection's peer.
public enum AskpassPeerVerdict: Sendable, Hashable {
    /// The peer may get a password; `sshPID` is the ssh process it asks for.
    case accepted(sshPID: pid_t)
    case rejected(String)
}

/// Decides whether the process behind an askpass connection may get a password.
public protocol AskpassPeerValidator: Sendable {
    func validate(socket fd: Int32) -> AskpassPeerVerdict
}

/// The production check. The peer must:
///
/// - run as this user;
/// - satisfy, looked up by audit token (not PID, which can be reused),
///   `anchor apple generic and certificate leaf[subject.OU] = "<team>" and identifier "app.aeroops.askpass"`,
///   where `<team>` is the app's own team ID;
/// - be the child of `/usr/bin/ssh`;
/// - descend from the app (through `login` and the shell for terminal tabs).
///
/// An app without a team ID (unsigned or ad-hoc) rejects every peer.
public struct SignedAskpassPeerValidator: AskpassPeerValidator {
    public let appProcessID: pid_t
    /// The team the helper must be signed by; `nil` when the app has none.
    public let teamIdentifier: String?
    private let requirementText: String?

    /// - Parameter teamIdentifier: Defaults to the running process's own team ID.
    public init(appProcessID: pid_t = getpid(), teamIdentifier: String? = SignedAskpassPeerValidator.ownTeamIdentifier()) {
        self.appProcessID = appProcessID
        // Only a well-formed team ID goes into the requirement string.
        let team = teamIdentifier.flatMap { $0.wholeMatch(of: /[A-Z0-9]{10}/) != nil ? $0 : nil }
        self.teamIdentifier = team
        requirementText = team.map {
            "anchor apple generic and certificate leaf[subject.OU] = \"\($0)\" and identifier \"\(Askpass.helperIdentifier)\""
        }
    }

    public func validate(socket fd: Int32) -> AskpassPeerVerdict {
        guard let uid = PeerInspector.peerUID(fd), uid == getuid() else { return .rejected("peer belongs to another user") }
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return .rejected("peer pid unavailable") }
        guard let requirementText else { return .rejected("AeroOps has no team ID in its code signature") }
        var token = audit_token_t()
        length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
              let code = PeerInspector.code(for: token) else { return .rejected("peer code signature unavailable") }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return .rejected("invalid code requirement") }
        guard SecCodeCheckValidity(code, [], requirement) == errSecSuccess else {
            let info = PeerInspector.signingInfo(code)
            let who = [info.identifier, info.team.map { "team \($0)" }].compactMap { $0 }.joined(separator: ", ")
            return .rejected("pid \(pid) (\(who.isEmpty ? "unsigned" : who)) is not AeroOps's askpass helper")
        }
        let ancestors = ProcessAncestry.ancestors(of: pid)
        guard let parent = ancestors.first, ProcessAncestry.executablePath(parent) == "/usr/bin/ssh" else {
            return .rejected("the helper was not started by /usr/bin/ssh")
        }
        guard ancestors.contains(appProcessID) else { return .rejected("the ssh asking was not started by AeroOps") }
        return .accepted(sshPID: parent)
    }

    /// The team ID of the running process's code signature, or `nil` when unsigned or ad-hoc.
    public static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        return PeerInspector.signingInfo(code).team
    }
}
