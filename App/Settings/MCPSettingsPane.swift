import AeroCore
import AeroTheme
import AgentBridge
import SwiftUI

/// Settings › MCP: the bridge's status, config snippets for MCP clients (copied, never written
/// to their config files), per-host access, approval options and the audit log.
struct MCPSettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                BridgeStatusSection()
                ConnectAgentSection()
                HostAccessSection()
                ApprovalSettingsSection()
                AuditLogSettingsSection()
            }
            .padding(20)
        }
        .background { Aero.sky.gradient.ignoresSafeArea() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("AI agents (MCP)")
                .font(Aero.font(.title2, weight: .semibold))
                .foregroundStyle(Aero.text.primary)
            Text("Claude Code, Codex and other MCP clients reach your servers through AeroOps. Agents never see your keys; they get only what each host's access level allows, every call is logged, and every command waits for your approval.")
                .font(Aero.font(.callout))
                .foregroundStyle(Aero.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Bridge

private struct BridgeStatusSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let agents = model.agents
        GlassSection("Bridge", systemImage: "point.3.connected.trianglepath.dotted") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    StatusOrb(tone: agents.status.tone, size: 10)
                    Text(agents.status.title)
                        .font(Aero.font(.callout, weight: .medium))
                        .foregroundStyle(Aero.text.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LabeledPath(label: "Socket", path: agents.socketURL.path(percentEncoded: false))
                if agents.peers.isEmpty {
                    Text("No agent connected. MCP clients start aeroops-mcp when they need it.")
                        .font(Aero.font(.caption))
                        .foregroundStyle(Aero.text.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(agents.peers) { peer in
                            Label {
                                Text(verbatim: "\(peer.peer.summary), since \(peer.since.formatted(date: .omitted, time: .shortened))")
                                    .foregroundStyle(Aero.text.primary)
                                    .textSelection(.enabled)
                            } icon: {
                                StatusOrb(tone: .healthy, size: 8)
                            }
                            .font(Aero.font(.caption))
                        }
                    }
                }
                Text("Only the aeroops-mcp inside this copy of AeroOps, signed by the same developer, may connect. Anything else is turned away and shown in Activity.")
                    .font(Aero.font(.caption))
                    .foregroundStyle(Aero.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } accessory: {
            AeroTag(agents.peersSummary, tint: agents.peers.isEmpty ? Aero.neutral : Aero.leaf)
        }
    }
}

/// A caption label and a selectable monospaced path. Also used by onboarding.
struct LabeledPath: View {
    let label: String
    let path: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(Aero.font(.caption, weight: .semibold))
                .foregroundStyle(Aero.text.secondary)
                .frame(width: 60, alignment: .leading)
            Text(verbatim: path)
                .font(Aero.font(.caption))
                .monospaced()
                .foregroundStyle(Aero.text.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Connect an agent

/// Config snippets for MCP clients, using the path of the aeroops-mcp in this app bundle. Also
/// onboarding's "AI agents" step.
struct ConnectAgentSection: View {
    @State private var copied: MCPClientConfig.Client?

    var body: some View {
        let path = MCPClientConfig.executablePath
        let exists = FileManager.default.isExecutableFile(atPath: path)
        GlassSection("Connect an agent", systemImage: "link") {
            VStack(alignment: .leading, spacing: 14) {
                LabeledPath(label: "Server", path: path)
                if !exists {
                    ValidationMessage(text: "aeroops-mcp is missing from this AeroOps.app. Reinstall AeroOps.")
                }
                ForEach(MCPClientConfig.Client.allCases) { client in
                    snippet(client, path: path)
                }
                VStack(alignment: .leading, spacing: 4) {
                    note("T3 Code runs Claude Code or Codex underneath and uses their MCP settings: add AeroOps there and it appears in T3 Code too.")
                    note("AeroOps never edits an agent's config files; copy the snippet and add it yourself. If you move AeroOps.app, copy it again.")
                }
            }
        }
    }

    private func snippet(_ client: MCPClientConfig.Client, path: String) -> some View {
        let text = MCPClientConfig.snippet(for: client, path: path)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(client.title)
                    .font(Aero.font(.callout, weight: .semibold))
                    .foregroundStyle(Aero.text.primary)
                Text(client.hint)
                    .font(Aero.font(.caption))
                    .foregroundStyle(Aero.text.secondary)
                Spacer()
                Button(copied == client ? "Copied" : "Copy", systemImage: copied == client ? "checkmark" : "doc.on.doc") {
                    Clipboard.copy(text)
                    copied = client
                }
                .buttonStyle(.aquaSecondary)
                .controlSize(.small)
                .accessibilityLabel("Copy \(client.title) config")
            }
            Text(verbatim: text)
                .font(Aero.font(.caption))
                .monospaced()
                .foregroundStyle(Aero.text.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background { Well(tint: Aero.aqua) }
        }
    }

    private func note(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(Aero.font(.caption))
            .foregroundStyle(Aero.text.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Config snippets for MCP clients.
enum MCPClientConfig {
    enum Client: String, CaseIterable, Identifiable {
        case claudeCode, codex, json
        var id: Self { self }

        var title: String {
            switch self {
            case .claudeCode: "Claude Code"
            case .codex: "Codex"
            case .json: "Other clients (JSON)"
            }
        }

        var hint: String {
            switch self {
            case .claudeCode: "run in Terminal"
            case .codex: "add to ~/.codex/config.toml"
            case .json: "mcpServers entry (Claude Desktop, Cursor, …)"
            }
        }
    }

    static let serverName = "aeroops"

    /// `AeroOps.app/Contents/MacOS/aeroops-mcp` of the running app.
    static var executablePath: String {
        let url = Bundle.main.url(forAuxiliaryExecutable: "aeroops-mcp")
            ?? Bundle.main.bundleURL.appending(path: "Contents/MacOS/aeroops-mcp")
        return url.path(percentEncoded: false)
    }

    static func snippet(for client: Client, path: String) -> String {
        switch client {
        case .claudeCode:
            "claude mcp add --scope user \(serverName) -- \(shellWord(path))"
        case .codex:
            "[mcp_servers.\(serverName)]\ncommand = \(tomlString(path))"
        case .json:
            json(path)
        }
    }

    /// The path as one shell word: as is when it has no special characters, else single-quoted.
    static func shellWord(_ path: String) -> String {
        let plain = path.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "/._-+@%:,".unicodeScalars.contains(scalar))
        }
        return plain && !path.isEmpty ? path : ShellQuote.quote(path)
    }

    /// A TOML basic string.
    static func tomlString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    static func json(_ path: String) -> String {
        struct Server: Encodable { let command: String }
        struct Config: Encodable { let mcpServers: [String: Server] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(Config(mcpServers: [serverName: Server(command: path)])) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Host access

private struct HostAccessSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassSection("Access per host", systemImage: "server.rack") {
            VStack(alignment: .leading, spacing: 10) {
                if model.hosts.isEmpty {
                    Text("No hosts yet.")
                        .font(Aero.font(.callout))
                        .foregroundStyle(Aero.text.secondary)
                } else {
                    ForEach(model.hosts) { host in
                        HStack(spacing: 10) {
                            Text(verbatim: host.name)
                                .font(Aero.font(.callout, weight: .semibold))
                                .foregroundStyle(Aero.text.primary)
                                .frame(width: 150, alignment: .leading)
                                .lineLimit(1)
                            AeroTag(host.mcpTier.title, systemImage: host.mcpTier.systemImage, tint: host.mcpTier.tint)
                                .frame(width: 120, alignment: .leading)
                            Text(host.mcpTier.explanation)
                                .font(Aero.font(.caption))
                                .foregroundStyle(Aero.text.secondary)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                        }
                    }
                }
                let counts = Dictionary(grouping: model.hosts, by: \.mcpTier).mapValues(\.count)
                Text(MCPTier.allCases.map { "\(counts[$0] ?? 0) \($0.title)" }.joined(separator: " · "))
                    .font(Aero.font(.caption))
                    .monospacedDigit()
                    .foregroundStyle(Aero.text.secondary)
            }
        } accessory: {
            Button("Edit Hosts…", systemImage: "pencil") { model.settingsPane = .hosts }
                .buttonStyle(.aquaSecondary)
                .controlSize(.small)
        }
    }
}

extension MCPTier {
    var tint: Color {
        switch self {
        case .off: Aero.neutral
        case .read: Aero.aqua
        case .readExec: Aero.sun
        }
    }

    var systemImage: String {
        switch self {
        case .off: "eye.slash"
        case .read: "eye"
        case .readExec: "terminal"
        }
    }
}

// MARK: - Approvals

private struct ApprovalSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var agents = model.agents
        GlassSection("Approvals", systemImage: "hand.raised") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $agents.requiresTouchID) {
                    Text("Require Touch ID to allow a command")
                        .font(Aero.font(.callout, weight: .medium))
                        .foregroundStyle(Aero.text.primary)
                    Text("Allow once and Allow host for 15 minutes ask for Touch ID or your login password first. Deny never asks.")
                        .font(Aero.font(.caption))
                        .foregroundStyle(Aero.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.switch)

                Text("Requests nobody answers are denied after 60 seconds. Commands using sudo, su or code they build or download are asked about every time, even while their host is allowed.")
                    .font(Aero.font(.caption))
                    .foregroundStyle(Aero.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if agents.windows.isEmpty {
                    Text("No host is allowed without asking right now.")
                        .font(Aero.font(.callout))
                        .foregroundStyle(Aero.text.secondary)
                } else {
                    AllowWindowList(windows: agents.windows) { hostID in
                        Task { await agents.revokeWindow(for: hostID) }
                    }
                }
                Button("Revoke All Allow Windows", systemImage: "xmark.shield", role: .destructive) {
                    Task { await agents.revokeAllWindows() }
                }
                .buttonStyle(.aquaSecondary)
                .disabled(agents.windows.isEmpty)
            }
        }
    }
}

// MARK: - Audit log

private struct AuditLogSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let url = model.agents.auditLogURL
        GlassSection("Audit log", systemImage: "list.bullet.rectangle") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledPath(label: "File", path: url.path(percentEncoded: false))
                Text("Every agent call is recorded as one JSON line: time, client, tool, host, arguments, decision and result. Command output is not stored. The file rotates automatically; Activity shows the latest entries.")
                    .font(Aero.font(.caption))
                    .foregroundStyle(Aero.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Reveal in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(.aquaSecondary)
                .disabled(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
            }
        }
    }
}

#Preview("MCP") {
    MCPSettingsPane()
        .environment(AppModel.preview())
        .frame(width: 780, height: 900)
}
