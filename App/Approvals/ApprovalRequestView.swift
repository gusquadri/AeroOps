import AeroTheme
import AgentBridge
import SwiftUI

/// One `run_command` approval: who asks (self-reported), where, the exact command, the agent's
/// reason, the auto-deny countdown and the decision buttons. Used by the floating approval panel
/// and the Activity tab.
///
/// Everything the agent sent is untrusted: shown as plain text (`Text(verbatim:)`), the command
/// in full (scrolls, never truncated) with invisible and direction-changing characters made
/// visible.
struct ApprovalRequestView: View {
    let approval: PendingApproval
    /// "2 of 3" when several approvals wait.
    var position: (index: Int, total: Int)?
    /// Freezes the countdown (snapshots).
    var fixedNow: Date?
    /// Whether an allow decision asks for Touch ID first (shown on the buttons).
    var requiresTouchID = false
    /// Answers the approval; `false` when it is gone or authentication failed.
    let onDecide: (ApprovalDecision) async -> Bool

    @State private var working: ApprovalDecision?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            commandWell
            reasonWell
            if !approval.alwaysAskReasons.isEmpty {
                alwaysAskNotice
            }
            ApprovalCountdown(requestedAt: approval.requestedAt, expiresAt: approval.expiresAt, fixedNow: fixedNow)
            if let failure {
                ValidationMessage(text: failure)
            }
            buttons
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "terminal")
                .font(Aero.font(size: 30, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Aero.aqua)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Run a command on \(approval.hostName)?")
                        .font(Aero.font(.title3, weight: .semibold))
                        .foregroundStyle(Aero.text.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if let position, position.total > 1 {
                        AeroTag("\(position.index) of \(position.total)", tint: Aero.neutral)
                    }
                }
                Text(verbatim: "\(approval.hostName) · \(approval.hostAddress)")
                    .font(Aero.font(.callout))
                    .monospaced()
                    .foregroundStyle(Aero.text.secondary)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    Text("Requested by")
                        .foregroundStyle(Aero.text.secondary)
                    Text(verbatim: VisibleText.escape(approval.clientLabel).text)
                        .foregroundStyle(Aero.text.primary)
                        .lineLimit(2)
                        .help("The MCP client chose this name itself. Any program can claim any name; AeroOps only verified that the request came through its own aeroops-mcp.")
                }
                .font(Aero.font(.callout, weight: .medium))
            }
        }
    }

    private var commandWell: some View {
        let visible = VisibleText.escape(approval.command)
        let lines = approval.command.split(separator: "\n", omittingEmptySubsequences: false).count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Command")
                    .font(Aero.font(.caption, weight: .semibold))
                    .foregroundStyle(Aero.text.secondary)
                if visible.hadHidden {
                    AeroTag("Hidden characters shown as ⟨U+…⟩", systemImage: "eye.trianglebadge.exclamationmark", tint: Aero.coral)
                }
                Spacer()
                Text("\(approval.command.count) characters\(lines > 1 ? ", \(lines) lines" : "")")
                    .font(Aero.font(.caption))
                    .monospacedDigit()
                    .foregroundStyle(Aero.text.secondary)
                Button {
                    Clipboard.copy(approval.command)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.aquaSecondary)
                .controlSize(.small)
                .help("Copy the exact command")
            }
            ScrollView(.vertical) {
                Text(verbatim: visible.text)
                    .font(Aero.font(.body))
                    .monospaced()
                    .foregroundStyle(Aero.text.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(minHeight: 44, maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
            .background { Well(tint: Aero.aqua) }
            .accessibilityLabel("Command: \(approval.command)")
        }
    }

    private var reasonWell: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Reason given by the agent (unverified)", systemImage: "quote.bubble")
                .font(Aero.font(.caption, weight: .semibold))
                .foregroundStyle(Aero.text.secondary)
            ScrollView(.vertical) {
                Text(verbatim: VisibleText.escape(approval.reason).text)
                    .font(Aero.font(.callout))
                    .italic()
                    .foregroundStyle(Aero.text.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 110)
            .fixedSize(horizontal: false, vertical: true)
            .background { Well(tint: Aero.neutral) }
        }
    }

    private var alwaysAskNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(approval.alwaysAskReasons, id: \.self) { reason in
                Label(reason.explanation, systemImage: "exclamationmark.shield")
                    .font(Aero.font(.callout, weight: .medium))
                    .foregroundStyle(Aero.text.primary)
            }
            Text("Commands like this are asked about every time, even while the host is allowed for 15 minutes.")
                .font(Aero.font(.caption))
                .foregroundStyle(Aero.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { Well(tint: Aero.sun) }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            if working != nil {
                ProgressView().controlSize(.small)
            }
            Spacer(minLength: 0)
            Button("Deny", role: .destructive) { decide(.deny) }
                .buttonStyle(.aquaSecondary)
                .keyboardShortcut(.cancelAction)
            if approval.offersHostWindow {
                Button("Allow host for 15 minutes", systemImage: requiresTouchID ? "touchid" : "clock") { decide(.allowHost15Min) }
                    .buttonStyle(.aquaSecondary)
                    .help("Run this and any further commands \(approval.hostName) gets in the next 15 minutes without asking (sudo and similar still ask).")
            }
            Button("Allow once", systemImage: requiresTouchID ? "touchid" : "checkmark") { decide(.allowOnce) }
                .buttonStyle(.aqua)
        }
        .disabled(working != nil)
    }

    private func decide(_ decision: ApprovalDecision) {
        working = decision
        failure = nil
        Task {
            let applied = await onDecide(decision)
            working = nil
            if !applied, decision != .deny, requiresTouchID {
                failure = "Not allowed: authentication did not succeed. The request is still waiting."
            }
        }
    }
}

// MARK: - Countdown

/// Time left before the approval is denied automatically.
struct ApprovalCountdown: View {
    let requestedAt: Date
    let expiresAt: Date
    var fixedNow: Date?

    /// Below this the bar turns coral.
    static let warning: TimeInterval = 10

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = fixedNow ?? context.date
            let total = max(expiresAt.timeIntervalSince(requestedAt), 1)
            let left = min(max(expiresAt.timeIntervalSince(now), 0), total)
            let urgent = left < Self.warning
            HStack(spacing: 10) {
                ProgressView(value: left, total: total)
                    .progressViewStyle(.linear)
                    .tint(urgent ? Aero.coral : Aero.aqua)
                Text("Denied automatically in \(Int(left.rounded(.up))) s")
                    .font(Aero.font(.caption, weight: urgent ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(Aero.text.secondary)
                    .fixedSize()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Denied automatically in \(Int(left.rounded(.up))) seconds")
        }
    }
}

// MARK: - Helpers

/// The opaque, tinted inner well used for command and reason text.
struct Well: View {
    var tint: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Aero.radius.inner, style: .continuous)
        shape.fill(Aero.glass.solidFill)
        shape.fill(tint.opacity(0.12))
        shape.strokeBorder(tint.opacity(0.45), lineWidth: 1)
    }
}

/// Makes text from agents and hosts safe to read: control, format (bidi overrides, zero-width
/// characters), separator and private-use characters become `⟨U+XXXX⟩`, so what is shown is
/// what runs. Newlines and tabs stay.
enum VisibleText {
    static func escape(_ text: String) -> (text: String, hadHidden: Bool) {
        var output = String.UnicodeScalarView()
        var hidden = false
        for scalar in text.unicodeScalars {
            if isHidden(scalar) {
                hidden = true
                output.append(contentsOf: "⟨U+\(String(scalar.value, radix: 16, uppercase: true).leftPadded(to: 4))⟩".unicodeScalars)
            } else {
                output.append(scalar)
            }
        }
        return (String(output), hidden)
    }

    private static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\n" || scalar == "\t" { return false }
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned:
            return true
        case .spaceSeparator:
            return scalar != " "
        default:
            // Combining marks on nothing visible and variation selectors can hide or alter text.
            return scalar.properties.isVariationSelector || scalar.properties.isDefaultIgnorableCodePoint
        }
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}
