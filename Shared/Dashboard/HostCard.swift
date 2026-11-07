import AeroCore
import AeroTheme
import Collectors
import SSHKit
import SwiftUI

/// A host's dashboard card: a status bubble with the host's system logo, name and address, with
/// uptime and the Files and Open SSH buttons in the top-right corner, then tags, all on a
/// title-bar wash in the host's status colour; CPU / memory / disk gauges below. Load is in the
/// inspector. Shared by the Mac dashboard and the iOS app.
///
/// Every card is the same size whatever the host's state: the tag row is always there, as tall
/// as a small button, so held host keys and untagged hosts don't change the height. The bubble's
/// colour is the status; what it means (the error, "Connecting…", the system it runs) is the
/// bubble's tooltip and the card's accessibility value, and the inspector shows it in full. Stale
/// or offline hosts keep their last numbers, dimmed, with "updated Xs ago" by the tags. A held
/// host key puts the button that resolves it there: Review… for a changed key, Review Key… for
/// a first key that is not trusted yet.
///
/// The tag row ends with the button that stops or resumes monitoring the host. A host with
/// monitoring off keeps its card, with empty gauges and "Monitoring off" by the tags.
struct HostCard: View, Equatable {
    let host: RemoteHost
    let state: HostDisplayState
    var isSelected = false
    /// Whether Open SSH and Files are available (both need the host's SSH connection).
    var canOpenSSH = false
    var onOpenSSH: () -> Void = {}
    /// Shows the host in the Files tab.
    var onBrowseFiles: () -> Void = {}
    /// Set when the host's key changed: the card shows Blocked and Review….
    var keyBlock: HostKeyBlock?
    /// Opens the host editor, where the full banner offers Trust New Key.
    var onReviewKey: () -> Void = {}
    /// Scans the host's first key and opens the trust sheet.
    var onTrustKey: () -> Void = {}
    var isScanningKey = false
    var keyScanError: String?
    /// Stops or resumes monitoring the host (``RemoteHost/monitored``).
    var onToggleMonitoring: () -> Void = {}

    /// Opacity of numbers that are no longer current.
    static let staleOpacity = 0.45

    /// Equal when everything but the actions is: those are new closures each time, and do the
    /// same thing for the same host. `state` is compared by identity; the card observes it.
    nonisolated static func == (lhs: HostCard, rhs: HostCard) -> Bool {
        lhs.state === rhs.state
            && (lhs.host, lhs.isSelected, lhs.canOpenSSH, lhs.keyBlock, lhs.isScanningKey, lhs.keyScanError)
            == (rhs.host, rhs.isSelected, rhs.canOpenSSH, rhs.keyBlock, rhs.isScanningKey, rhs.keyScanError)
    }
    /// The name column's width before the buttons shrink to small, then uptime goes.
    private static let nameIdealWidth: CGFloat = 110

    var body: some View {
        let metrics = state.metrics
        let dimmed = state.showsOldNumbers || !host.monitored
        let shape = RoundedRectangle(cornerRadius: Aero.radius.card, style: .continuous)
        AeroCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                HStack(alignment: .top, spacing: 0) {
                    Spacer(minLength: 8)
                    GlossyGauge(value: metrics?.cpuPercent.map { $0 / 100 }, label: "CPU")
                        .help(cpuHelp(metrics))
                    Spacer(minLength: 8)
                    GlossyGauge(value: metrics?.memUsedFraction, label: "Memory")
                        .help(metrics.map { "Memory: \(MetricText.usage($0.memUsedBytes, of: $0.memTotalBytes))" } ?? "Memory")
                    Spacer(minLength: 8)
                    GlossyGauge(value: metrics?.cardDisk()?.usedFraction, label: "Disk")
                        .help(diskHelp(metrics))
                    Spacer(minLength: 8)
                }
                .opacity(dimmed ? Self.staleOpacity : 1)
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
        }
        .overlay {
            if isSelected {
                shape.stroke(Aero.aqua.opacity(0.3), lineWidth: 7)
                    .allowsHitTesting(false)
                shape.strokeBorder(Aero.aqua, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(host.name)
        .accessibilityValue(([statusTitle, statusDetail] + (state.status == .online ? [] : systemLines)).joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        #if os(macOS)
        .accessibilityHint("Double-click for details")
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                StatusBubble(tone: orbTone, logo: state.systemLogo, size: 44)
                    .help(statusHelp)
                    .accessibilityHidden(true)
                HorizontalFit(Self.titleLayouts) { layout in
                    titleRow(layout)
                }
            }
            ZStack(alignment: .leading) {
                Button("Review…") {}
                    .buttonStyle(.aquaSecondary)
                    .controlSize(.small)
                    .hidden()
                    .accessibilityHidden(true)
                HStack(spacing: 8) {
                    if host.tags.isEmpty {
                        Spacer(minLength: 8)
                    } else {
                        HorizontalFit([4, 3, 2, 1]) { limit in
                            TagRow(tags: host.tags, limit: limit)
                        }
                        .padding(.trailing, 8)
                    }
                    accessory
                    monitoringButton
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background { AeroHeaderWash(tint: orbTone.color) }
    }

    /// The title row's layouts, widest first.
    private static let titleLayouts = [
        TitleLayout(buttonSize: .regular, showsUptime: true),
        TitleLayout(buttonSize: .small, showsUptime: true),
        TitleLayout(buttonSize: .small, showsUptime: false),
    ]

    private struct TitleLayout: Hashable {
        let buttonSize: ControlSize
        let showsUptime: Bool
    }

    /// Name and address, then uptime and the Files and Open SSH buttons.
    private func titleRow(_ layout: TitleLayout) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(host.name)
                    .font(Aero.font(.title3, weight: .semibold))
                    .foregroundStyle(Aero.text.primary)
                    .lineLimit(1)
                Text(host.connectionSummary)
                    .font(Aero.font(.callout))
                    .foregroundStyle(Aero.text.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minWidth: 0, idealWidth: Self.nameIdealWidth, maxWidth: .infinity, alignment: .leading)
            if layout.showsUptime {
                uptime
            }
            HStack(spacing: 8) {
                filesButton
                openSSHButton
            }
            .controlSize(layout.buttonSize)
        }
    }

    /// Laid out around a hidden sample ("99d 23h") with the real figure drawn over it, so every
    /// card of a width picks the same buttons whatever its uptime.
    private var uptime: some View {
        CardFigure(label: "Uptime", value: Self.sampleUptime, alignment: .trailing)
            .hidden()
            .overlay(alignment: .trailing) {
                CardFigure(label: "Uptime", value: MetricText.uptime(state.metrics?.uptimeSeconds), alignment: .trailing)
                    .opacity(state.showsOldNumbers || !host.monitored ? Self.staleOpacity : 1)
            }
            .fixedSize()
    }

    private static let sampleUptime = MetricText.uptime(99 * 86_400 + 23 * 3_600)

    private var filesButton: some View {
        Button("Files", systemImage: "folder", action: onBrowseFiles)
            .labelStyle(.iconOnly)
            .buttonStyle(.aquaSecondary)
            .fixedSize()
            .disabled(!canOpenSSH)
            .help(actionHelp(available: "Browse the files of \(host.name) over SFTP", notYet: "Files aren't available for \(host.name) yet."))
    }

    private var openSSHButton: some View {
        Button("Open SSH", systemImage: "terminal", action: onOpenSSH)
            .labelStyle(.iconOnly)
            .buttonStyle(.aqua)
            .fixedSize()
            .disabled(!canOpenSSH)
            .help(actionHelp(available: "Open a terminal tab to \(host.name)", notYet: "Terminal tabs aren't available for \(host.name) yet."))
    }

    /// Stops or resumes polling the host. Its terminals, files and containers work either way.
    private var monitoringButton: some View {
        Button(
            host.monitored ? "Stop Monitoring" : "Start Monitoring",
            systemImage: host.monitored ? "pause.fill" : "play.fill",
            action: onToggleMonitoring
        )
        .labelStyle(.iconOnly)
        .buttonStyle(.aquaSecondary)
        .controlSize(.small)
        .fixedSize()
        .help(host.monitored ? "Stop polling \(host.name) for metrics" : "Poll \(host.name) for metrics again")
    }

    /// The button that resolves a held host key (Review… for a changed key, Review Key… for a
    /// first key), the age of old numbers, or "Monitoring off".
    @ViewBuilder private var accessory: some View {
        if keyBlock != nil {
            Button("Review…", action: onReviewKey)
                .buttonStyle(.aquaSecondary)
                .controlSize(.small)
                .fixedSize()
                .help("Compare the fingerprints in the host editor and decide whether to trust the new key")
        } else if state.needsHostKeyTrust {
            HStack(spacing: 6) {
                if isScanningKey {
                    ProgressView().controlSize(.small)
                } else if let keyScanError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Aero.font(.caption))
                        .foregroundStyle(Aero.coral)
                        .help(keyScanError)
                        .accessibilityLabel(keyScanError)
                }
                Button("Review Key…", action: onTrustKey)
                    .buttonStyle(.aquaSecondary)
                    .controlSize(.small)
                    .disabled(isScanningKey)
                    .help("Show the fingerprints this host presents and trust them to start monitoring")
            }
            .fixedSize()
        } else if !host.monitored {
            Text("Monitoring off")
                .font(Aero.font(.caption, weight: .medium))
                .foregroundStyle(Aero.text.secondary)
                .lineLimit(1)
                .fixedSize()
        } else if let since = agedSince {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("updated \(MetricText.age(of: since, now: context.date)) ago")
                    .font(Aero.font(.caption, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Aero.text.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    /// When the numbers on screen were sampled, if they are old.
    private var agedSince: Date? {
        guard state.showsOldNumbers else { return nil }
        return state.metrics?.sampledAt ?? state.lastSuccessAt
    }

    /// The distribution ("Ubuntu 24.04.1 LTS") and kernel line, those that are known.
    private var systemLines: [String] {
        [state.metrics?.os?.displayName, state.metrics?.kernel.nilIfEmpty ?? state.unsupportedSystem].compactMap { $0 }
    }

    /// What the status means, in a sentence: why the host is not polled or not online,
    /// "Connecting…", or the system it runs.
    private var statusDetail: String {
        if keyBlock != nil { return "Host key changed. Not polled until you review it." }
        if state.needsHostKeyTrust { return keyScanError ?? "Not polled until you trust its host key." }
        switch state.status {
        case .loading: return state.message ?? "Connecting…"
        case .online: return systemLines.first ?? "Online"
        case .stale: return state.message ?? "The last poll failed."
        case .offline: return state.message ?? "Not answering."
        case .unsupported: return state.message ?? "Unsupported OS."
        case .unmonitored: return "Monitoring is off. Not polled."
        }
    }

    /// The bubble's tooltip: the full error or the held key's fingerprints, then the system.
    private var statusHelp: String {
        let reason: String
        if let keyBlock {
            reason = keyBlock.helpText
        } else if state.needsHostKeyTrust || state.status == .online {
            reason = statusDetail
        } else {
            reason = state.lastError ?? statusDetail
        }
        return ([reason] + systemLines.filter { $0 != reason }).joined(separator: "\n")
    }

    private var orbTone: OrbTone {
        state.orbTone(blocked: keyBlock != nil)
    }

    private var statusTitle: String {
        state.title(blocked: keyBlock != nil)
    }

    /// Tooltip for Open SSH or Files: `available`, or why the button is disabled.
    private func actionHelp(available: String, notYet: String) -> String {
        if canOpenSSH { return available }
        if keyBlock != nil { return "Blocked: the host key of \(host.name) changed. Review it first." }
        if state.needsHostKeyTrust { return "Trust the host key of \(host.name) first." }
        return notYet
    }

    private func cpuHelp(_ metrics: MetricsSnapshot?) -> String {
        guard let metrics else { return "CPU" }
        let cores = metrics.cpuCount.map { $0 == 1 ? "1 CPU" : "\($0) CPUs" } ?? "CPU"
        return metrics.cpuPercent == nil ? "\(cores): measured from the second sample" : cores
    }

    private func diskHelp(_ metrics: MetricsSnapshot?) -> String {
        guard let disk = metrics?.cardDisk() else { return "Disk: /" }
        return "Disk \(disk.mount): \(MetricText.usage(disk.usedBytes, of: disk.totalBytes))"
    }
}

/// "6 hosts" and a status chip per state ("2 online", "1 offline") above the cards.
struct HostStatusSummary: View {
    /// Hosts per status.
    let counts: [HostStatus: Int]

    /// One line when it fits (the Mac); on a phone the tags go under the count, and scroll
    /// sideways if they still don't fit.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                total
                tags
            }
            VStack(alignment: .leading, spacing: 6) {
                total
                HStack(spacing: 8) { tags }
            }
            VStack(alignment: .leading, spacing: 6) {
                total
                ScrollView(.horizontal) {
                    HStack(spacing: 8) { tags }
                }
                .scrollIndicators(.hidden)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var total: some View {
        let total = counts.values.reduce(0, +)
        return Text(total == 1 ? "1 host" : "\(total) hosts")
            .font(Aero.font(.headline, weight: .semibold))
            .foregroundStyle(Aero.text.primary)
    }

    private var tags: some View {
        let statuses = [HostStatus.online, .stale, .offline, .unsupported, .loading, .unmonitored].filter { counts[$0] != nil }
        return ForEach(statuses, id: \.self) { status in
            AeroTag("\(counts[status] ?? 0) \(status.summaryLabel)", tone: status.orbTone)
                .fixedSize()
        }
    }
}

/// A small caption + value pair on a card ("Uptime 12d 4h").
private struct CardFigure: View {
    let label: String
    let value: String
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(label)
                .font(Aero.font(.caption, weight: .medium))
                .foregroundStyle(Aero.text.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(Aero.font(.callout, weight: .semibold))
                .foregroundStyle(Aero.text.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }
}

extension HostDisplayState {
    /// The orb tone, accounting for host-key holds: a changed key is an error, an untrusted
    /// first key needs attention.
    func orbTone(blocked: Bool) -> OrbTone {
        if blocked || isChangedKey { return .error }
        if needsHostKeyTrust { return .warning }
        return status.orbTone
    }

    /// The short status label next to the orb.
    func title(blocked: Bool) -> String {
        if blocked || isChangedKey { return "Blocked" }
        if needsHostKeyTrust { return "Key not trusted" }
        return status.title
    }

    /// The logo in the status bubble, from the last sample's os-release and kernel (or the
    /// `uname` of an unsupported host); `nil`, a generic server, until the host has answered.
    var systemLogo: SystemLogo? {
        SystemLogo.match(
            id: metrics?.os?.id,
            idLike: metrics?.os?.idLike ?? [],
            kernel: metrics?.kernel.nilIfEmpty ?? unsupportedSystem
        )
    }

    private var isChangedKey: Bool {
        if case .changed = hostKeyIssue { true } else { false }
    }
}

extension String {
    /// `nil` for an empty string.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

#Preview("Host cards · every state") {
    let hosts = SampleData.hosts
    let updates = SampleData.liveUpdates(for: hosts)
    let states = hosts.map { host -> HostDisplayState in
        let state = HostDisplayState(hostID: host.id)
        if let update = updates.first(where: { $0.hostID == host.id }) {
            state.apply(update)
        } else {
            state.reset(status: .unmonitored)
        }
        return state
    }
    ScrollView {
        VStack(spacing: 16) {
            ForEach(hosts.indices, id: \.self) { index in
                HostCard(host: hosts[index], state: states[index])
            }
        }
        .padding(20)
    }
    .background { SkyBackground() }
}
