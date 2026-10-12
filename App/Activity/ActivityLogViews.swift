import AeroCore
import AeroTheme
import AgentBridge
import BridgeProtocol
import KeyAgent
import SwiftUI

// MARK: - Commands

/// Running `run_command` calls (with Cancel) and the last few finished ones, with their output.
struct CommandsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let agents = model.agents
        GlassSection("Agent commands", systemImage: "terminal") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(agents.liveCommands.enumerated()), id: \.element.id) { index, command in
                    if index > 0 { Divider() }
                    LiveCommandView(command: command) {
                        Task { await agents.cancel(command.id) }
                    }
                }
            }
        } accessory: {
            if agents.liveCommands.contains(where: { !$0.isRunning }) {
                Button("Clear Finished") { agents.clearFinishedCommands() }
                    .buttonStyle(.aquaSecondary)
                    .controlSize(.small)
            }
        }
    }
}

/// One command: host, the command line, its state, Cancel while it runs, and its output.
struct LiveCommandView: View {
    let command: LiveCommand
    let onCancel: () -> Void

    @State private var isCancelling = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if command.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    StatusOrb(tone: command.state.tone, size: 10)
                }
                Text(verbatim: command.hostName)
                    .font(Aero.font(.callout, weight: .semibold))
                    .foregroundStyle(Aero.text.primary)
                stateTag
                Spacer(minLength: 8)
                if command.isRunning {
                    Button("Cancel", systemImage: "stop.circle", role: .destructive) {
                        isCancelling = true
                        onCancel()
                    }
                    .buttonStyle(.aquaSecondary)
                    .controlSize(.small)
                    .disabled(isCancelling)
                    .help("Stop this command: ssh is closed and the command is killed on the host.")
                }
            }
            Text(verbatim: VisibleText.escape(command.command).text)
                .font(Aero.monospacedFont(.callout))
                .foregroundStyle(Aero.text.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if command.hasOutput {
                output
            } else if command.isRunning {
                Text("No output yet.")
                    .font(Aero.font(.caption))
                    .foregroundStyle(Aero.text.secondary)
            }
        }
    }

    @ViewBuilder private var stateTag: some View {
        switch command.state {
        case .running:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                AeroTag("Running \(Self.elapsed(from: command.startedAt, to: context.date))", tint: Aero.aqua)
            }
        case .finished(let exitCode, let durationMs):
            AeroTag("Exit \(exitCode) · \(DisplayDuration.milliseconds(durationMs))", tone: exitCode == 0 ? .healthy : .warning)
        case .failed(let message):
            AeroTag("Failed: \(message)", tone: .error)
        case .cancelled(let byUser):
            AeroTag(byUser ? "Cancelled by you" : "Cancelled by the agent", tone: .neutral)
        }
    }

    private var output: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(command.segments) { segment in
                        HStack(alignment: .top, spacing: 6) {
                            Rectangle()
                                .fill(segment.stream == .stderr ? Aero.coral : Aero.aqua.opacity(0.5))
                                .frame(width: 3)
                                .accessibilityHidden(true)
                            Text(verbatim: segment.text)
                                .font(Aero.monospacedFont(.caption))
                                .foregroundStyle(Aero.text.primary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityLabel(segment.stream == .stderr ? "stderr: \(segment.text)" : segment.text)
                    }
                }
                .padding(10)
            }
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
            .background { Well(tint: Aero.neutral) }
            HStack(spacing: 10) {
                Label("stdout", systemImage: "square.fill").foregroundStyle(Aero.text.secondary)
                    .labelStyle(LegendLabelStyle(tint: Aero.aqua.opacity(0.5)))
                Label("stderr", systemImage: "square.fill").foregroundStyle(Aero.text.secondary)
                    .labelStyle(LegendLabelStyle(tint: Aero.coral))
                Spacer()
                Text(command.isTruncated
                     ? "Showing the first \(ByteCountFormatter.string(fromByteCount: Int64(LiveCommand.outputLimit), countStyle: .binary)); the rest was dropped"
                     : ByteCountFormatter.string(fromByteCount: Int64(command.byteCount), countStyle: .binary))
                    .monospacedDigit()
                    .foregroundStyle(command.isTruncated ? Aero.text.primary : Aero.text.secondary)
            }
            .font(Aero.font(.caption2))
        }
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(Int(now.timeIntervalSince(start)), 0)
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

private struct LegendLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(tint).imageScale(.small)
            configuration.title
        }
    }
}

extension LiveCommand.State {
    var tone: OrbTone {
        switch self {
        case .running: .healthy
        case .finished(let exitCode, _): exitCode == 0 ? .healthy : .warning
        case .failed: .error
        case .cancelled: .neutral
        }
    }
}

/// "412 ms", "2.4 s", "1 min 3 s".
enum DisplayDuration {
    static func milliseconds(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms) ms" }
        if ms < 60_000 { return String(format: "%.1f s", Double(ms) / 1000) }
        return "\(ms / 60_000) min \((ms % 60_000) / 1000) s"
    }
}

// MARK: - Connections and signing

/// The in-app ssh-agent's events (signatures, connections) and the MCP bridge's connections,
/// newest first, filterable by kind.
struct ConnectionEventsSection: View {
    @Environment(AppModel.self) private var model
    @State private var filter: Filter = .all

    static let rowLimit = 100

    enum Filter: String, CaseIterable, Identifiable {
        case all, signatures, sshAgent, bridge
        var id: Self { self }

        var title: String {
            switch self {
            case .all: "All"
            case .signatures: "Signatures"
            case .sshAgent: "ssh-agent"
            case .bridge: "MCP bridge"
            }
        }
    }

    struct Row: Identifiable {
        enum Source { case sshAgent, bridge }
        let id: String
        let date: Date
        let source: Source
        let isSignature: Bool
        let tone: OrbTone
        let summary: String
    }

    var body: some View {
        let rows = rows()
        GlassSection("Connections and signatures", systemImage: "signature") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                .labelsHidden()
                if rows.isEmpty {
                    Text("No events yet.")
                        .font(Aero.font(.callout))
                        .foregroundStyle(Aero.text.secondary)
                } else {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(rows.prefix(Self.rowLimit)) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                StatusOrb(tone: row.tone, size: 8)
                                Text(row.date.formatted(date: .omitted, time: .standard))
                                    .monospacedDigit()
                                    .foregroundStyle(Aero.text.secondary)
                                    .frame(width: 80, alignment: .leading)
                                AeroTag(row.source == .bridge ? "MCP" : "ssh-agent", tint: row.source == .bridge ? Aero.aqua : Aero.neutral)
                                    .frame(width: 84, alignment: .leading)
                                Text(verbatim: row.summary)
                                    .foregroundStyle(Aero.text.primary)
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .help(row.summary)
                            }
                            .font(Aero.font(.caption))
                        }
                    }
                }
            }
        }
    }

    private func rows() -> [Row] {
        var rows: [Row] = []
        if filter != .bridge {
            for (index, event) in model.ssh.agentEvents.enumerated() {
                let isSignature: Bool
                switch event.kind {
                case .signed, .signFailed: isSignature = true
                default: isSignature = false
                }
                if filter == .signatures && !isSignature { continue }
                rows.append(Row(id: "agent-\(index)-\(event.date.timeIntervalSinceReferenceDate)", date: event.date, source: .sshAgent,
                                isSignature: isSignature, tone: event.tone, summary: VisibleText.escape(event.summary).text))
            }
        }
        if filter == .all || filter == .bridge {
            for record in model.agents.connectionEvents {
                rows.append(Row(id: record.id.uuidString, date: record.date, source: .bridge, isSignature: false,
                                tone: record.tone, summary: VisibleText.escape(record.summary).text))
            }
        }
        return rows.sorted { $0.date > $1.date }
    }
}

extension AgentEvent {
    var tone: OrbTone {
        switch kind {
        case .signed, .connected, .identitiesListed, .sessionBound: .healthy
        case .signFailed, .refused, .rejected: .error
        case .disconnected: .neutral
        }
    }
}

extension BridgeService.ConnectionRecord {
    var summary: String {
        switch kind {
        case .connected(let peer): "Connection \(connectionID): aeroops-mcp connected, \(peer.summary)"
        case .rejected(let reason): "Connection \(connectionID) rejected: \(reason)"
        case .protocolError(let message): "Connection \(connectionID) protocol error: \(message)"
        case .disconnected: "Connection \(connectionID) closed"
        }
    }

    var tone: OrbTone {
        switch kind {
        case .connected: .healthy
        case .rejected, .protocolError: .error
        case .disconnected: .neutral
        }
    }
}
