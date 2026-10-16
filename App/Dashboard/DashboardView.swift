import AeroCore
import AeroTheme
import Collectors
import SSHKit
import SwiftUI

/// Dashboard tab: one card per host, fed live by ``MonitorService``, and the selected host's
/// details in an inspector.
///
/// Each card observes only its own ``HostDisplayState``, so a poll result redraws one card.
/// Selecting a host in the sidebar or double-clicking a card opens ``HostDetailView``;
/// Refresh (⌘R) polls every host now.
struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var showsDetail = false
    /// Set by a single click on a card, so that selection does not open the inspector.
    @State private var selectedFromCard = false

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 20, alignment: .top)]

    var body: some View {
        @Bindable var monitoring = model.monitoring
        content
            .inspector(isPresented: $showsDetail) {
                detail
                    .inspectorColumnWidth(min: 320, ideal: 360, max: 480)
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") { model.refreshAll() }
                        .keyboardShortcut("r")
                        .help("Poll every host now (⌘R)")
                        .disabled(model.hosts.isEmpty)
                    Button("Details", systemImage: "sidebar.trailing") { showsDetail.toggle() }
                        .keyboardShortcut("i", modifiers: [.command, .option])
                        .help(showsDetail ? "Hide host details (⌥⌘I)" : "Show the selected host's details (⌥⌘I)")
                        .disabled(model.hosts.isEmpty)
                }
            }
            .onChange(of: model.selection) { _, selection in
                if selectedFromCard {
                    selectedFromCard = false
                } else if selection != nil {
                    showsDetail = true
                }
            }
            .sheet(item: $monitoring.trustRequest) { request in
                HostKeyTrustSheet(
                    host: request.host,
                    offered: request.offered,
                    onTrust: { try await model.monitoring.trust(request) },
                    onCancel: { model.monitoring.trustRequest = nil }
                )
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.hosts.isEmpty {
            AeroEmptyState(
                systemImage: "square.grid.2x2",
                title: "Your servers will appear here",
                message: "Add a host to see its CPU, memory, disk, uptime and load at a glance, refreshed every few seconds over SSH."
            ) {
                AddHostButton()
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DashboardSummary()
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                        ForEach(model.hosts) { host in
                            card(for: host)
                        }
                    }
                }
                .padding(24)
            }
        }
    }

    private func card(for host: RemoteHost) -> some View {
        HostCard(
            host: host,
            state: model.displayState(for: host.id),
            isSelected: model.selection == host.id,
            canOpenSSH: model.canOpenSSH(host.id),
            onOpenSSH: { model.openSSH(host.id) },
            onBrowseFiles: { model.browseFiles(host.id) },
            keyBlock: model.hostKeyBlock(for: host.id),
            onReviewKey: { model.requestEdit(host.id) },
            onTrustKey: { Task { await model.monitoring.requestHostKeyTrust(for: host) } },
            isScanningKey: model.monitoring.scanningHostIDs.contains(host.id),
            keyScanError: model.monitoring.scanErrors[host.id]
        )
        .onTapGesture(count: 2) {
            select(host.id, fromCard: true)
            showsDetail = true
        }
        .onTapGesture {
            select(host.id, fromCard: true)
        }
    }

    private func select(_ id: RemoteHost.ID, fromCard: Bool) {
        guard model.selection != id else { return }
        selectedFromCard = fromCard
        model.selection = id
    }

    @ViewBuilder
    private var detail: some View {
        if let host = model.selectedHost {
            HostDetailView(host: host, state: model.displayState(for: host.id), keyBlock: model.hostKeyBlock(for: host.id))
        } else {
            ContentUnavailableView("No Host Selected", systemImage: "server.rack", description: Text("Select a host in the sidebar or double-click a card."))
                .font(Aero.font(.body))
                .foregroundStyle(Aero.text.secondary)
        }
    }
}

/// "6 hosts" and a status chip per state ("2 online", "1 offline") above the grid.
private struct DashboardSummary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let counts = model.statusCounts()
        let statuses = [HostStatus.online, .stale, .offline, .unsupported, .loading].filter { counts[$0] != nil }
        let total = model.hosts.count
        HStack(spacing: 8) {
            Text(total == 1 ? "1 host" : "\(total) hosts")
                .font(Aero.font(.headline, weight: .semibold))
                .foregroundStyle(Aero.text.primary)
            ForEach(statuses, id: \.self) { status in
                AeroTag("\(counts[status] ?? 0) \(status.summaryLabel)", tone: status.orbTone)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A host's dashboard card: a status bubble with the host's system logo, name and address, with
/// uptime and the Files and Open SSH buttons in the top-right corner, then tags, all on a
/// title-bar wash in the host's status colour; CPU / memory / disk gauges below. Load is in the
/// inspector.
///
/// Every card is the same size whatever the host's state: the tag row is always there, as tall
/// as a small button, so held host keys and untagged hosts don't change the height. The bubble's
/// colour is the status; what it means (the error, "Connecting…", the system it runs) is the
/// bubble's tooltip and the card's accessibility value, and the inspector shows it in full. Stale
/// or offline hosts keep their last numbers, dimmed, with "updated Xs ago" by the tags. A held
/// host key puts the button that resolves it there: Review… for a changed key, Review Key… for
/// a first key that is not trusted yet.
struct HostCard: View {
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

    /// Opacity of numbers that are no longer current.
    static let staleOpacity = 0.45
    /// The name column's width before the buttons shrink to small, then uptime goes.
    private static let nameIdealWidth: CGFloat = 110

    var body: some View {
        let metrics = state.metrics
        let dimmed = state.showsOldNumbers
        let shape = RoundedRectangle(cornerRadius: Aero.radius.card, style: .continuous)
        AeroCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                HStack(alignment: .top) {
                    GlossyGauge(value: metrics?.cpuPercent.map { $0 / 100 }, label: "CPU")
                        .help(cpuHelp(metrics))
                    Spacer(minLength: 8)
                    GlossyGauge(value: metrics?.memUsedFraction, label: "Memory")
                        .help(metrics.map { "Memory: \(MetricText.usage($0.memUsedBytes, of: $0.memTotalBytes))" } ?? "Memory")
                    Spacer(minLength: 8)
                    GlossyGauge(value: metrics?.cardDisk()?.usedFraction, label: "Disk")
                        .help(diskHelp(metrics))
                }
                .opacity(dimmed ? Self.staleOpacity : 1)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
        }
        .overlay {
            if isSelected {
                // A soft aqua halo around a crisp aqua rim.
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
        .accessibilityHint("Double-click for details")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                StatusBubble(tone: orbTone, logo: state.systemLogo, size: 44)
                    .help(statusHelp)
                    // The card's accessibility value says the status and the system.
                    .accessibilityHidden(true)
                // Narrower cards get small buttons, then drop uptime (the inspector shows it), so
                // the name keeps room down to the grid's 300 pt minimum.
                ViewThatFits(in: .horizontal) {
                    titleRow(buttonSize: .regular, showsUptime: true)
                    titleRow(buttonSize: .small, showsUptime: true)
                    titleRow(buttonSize: .small, showsUptime: false)
                }
            }
            ZStack(alignment: .leading) {
                // As tall as a small button, so cards showing Review… are no taller.
                Button("Review…") {}
                    .buttonStyle(.aquaSecondary)
                    .controlSize(.small)
                    .hidden()
                    .accessibilityHidden(true)
                HStack(spacing: 8) {
                    if !host.tags.isEmpty {
                        // Fewer tags (and "+N") where the accessory needs the room.
                        ViewThatFits(in: .horizontal) {
                            ForEach([4, 3, 2, 1], id: \.self) { limit in
                                TagRow(tags: host.tags, limit: limit)
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    accessory
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background { AeroHeaderWash(tint: orbTone.color) }
    }

    /// Name and address, then uptime and the Files and Open SSH buttons.
    private func titleRow(buttonSize: ControlSize, showsUptime: Bool) -> some View {
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
            if showsUptime {
                uptime
            }
            HStack(spacing: 8) {
                filesButton
                openSSHButton
            }
            .controlSize(buttonSize)
        }
    }

    /// Laid out around a hidden sample ("99d 23h") with the real figure drawn over it, so every
    /// card of a width picks the same buttons whatever its uptime.
    private var uptime: some View {
        CardFigure(label: "Uptime", value: Self.sampleUptime, alignment: .trailing)
            .hidden()
            .overlay(alignment: .trailing) {
                CardFigure(label: "Uptime", value: MetricText.uptime(state.metrics?.uptimeSeconds), alignment: .trailing)
                    .opacity(state.showsOldNumbers ? Self.staleOpacity : 1)
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

    /// The button that resolves a held host key (Review… for a changed key, Review Key… for a
    /// first key), or the age of old numbers.
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

#Preview("Dashboard · every status") {
    DashboardView()
        .environment(AppModel.preview(withMetrics: true))
        .background { SkyBackground() }
        .frame(width: 1000, height: 700)
}

#Preview("Dashboard · empty") {
    DashboardView()
        .environment(AppModel.preview(hosts: []))
        .background { SkyBackground() }
        .frame(width: 800, height: 600)
}
