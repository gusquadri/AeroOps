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

/// A host's dashboard card: orb, name, address and tags on a title-bar wash in the host's status
/// colour, CPU / memory / disk gauges, uptime, load, an Open SSH button and a status well.
///
/// Every card is the same size whatever the host's state: the tag row and the well's two lines
/// are always reserved, so errors, held host keys and untagged hosts don't change the height.
/// Stale or offline hosts keep their last numbers, dimmed, with "updated Xs ago". A held host
/// key turns the well into a notice with the button that resolves it.
struct HostCard: View {
    let host: RemoteHost
    let state: HostDisplayState
    var isSelected = false
    var canOpenSSH = false
    var onOpenSSH: () -> Void = {}
    /// Set when the host's key changed: the well shows the blocked notice.
    var keyBlock: HostKeyBlock?
    /// Opens the host editor, where the full banner offers Trust New Key.
    var onReviewKey: () -> Void = {}
    /// Scans the host's first key and opens the trust sheet.
    var onTrustKey: () -> Void = {}
    var isScanningKey = false
    var keyScanError: String?

    /// Opacity of numbers that are no longer current.
    static let staleOpacity = 0.45

    var body: some View {
        let metrics = state.metrics
        let dimmed = state.showsOldNumbers
        let shape = RoundedRectangle(cornerRadius: Aero.radius.card, style: .continuous)
        AeroCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(alignment: .leading, spacing: 14) {
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
                    .padding(.horizontal, 8)
                    .opacity(dimmed ? Self.staleOpacity : 1)
                    // Narrow cards (the grid's 300 pt minimum) drop the button's title, then
                    // let the figures shrink, so the row never wraps.
                    ViewThatFits(in: .horizontal) {
                        figuresRow(metrics, dimmed: dimmed, buttonTitle: true, fixed: true)
                        figuresRow(metrics, dimmed: dimmed, buttonTitle: false, fixed: true)
                        figuresRow(metrics, dimmed: dimmed, buttonTitle: false, fixed: false)
                    }
                    CardStatusWell(
                        state: state,
                        keyBlock: keyBlock,
                        isScanningKey: isScanningKey,
                        keyScanError: keyScanError,
                        onReviewKey: onReviewKey,
                        onTrustKey: onTrustKey
                    )
                }
                .padding(16)
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
        .accessibilityValue(statusTitle)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Double-click for details")
    }

    private func figuresRow(_ metrics: MetricsSnapshot?, dimmed: Bool, buttonTitle: Bool, fixed: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            figures(metrics, dimmed: dimmed)
                .fixedSize(horizontal: fixed, vertical: false)
            Spacer(minLength: 8)
            openSSHButton(title: buttonTitle)
        }
    }

    private func figures(_ metrics: MetricsSnapshot?, dimmed: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            CardFigure(label: "Uptime", value: MetricText.uptime(metrics?.uptimeSeconds))
            CardFigure(label: "Load 1 · 5 · 15", value: MetricText.load(metrics))
        }
        .opacity(dimmed ? Self.staleOpacity : 1)
    }

    private func openSSHButton(title: Bool) -> some View {
        Button("Open SSH", systemImage: "terminal", action: onOpenSSH)
            .labelStyle(OpenSSHLabelStyle(showsTitle: title))
            .buttonStyle(.aqua)
            .fixedSize()
            .disabled(!canOpenSSH)
            .help(openSSHHelp)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusOrb(tone: orbTone, size: 14)
                Text(host.name)
                    .font(Aero.font(.title3, weight: .semibold))
                    .foregroundStyle(Aero.text.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(statusTitle)
                    .font(Aero.font(.caption, weight: .semibold))
                    .foregroundStyle(Aero.text.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Text(host.connectionSummary)
                .font(Aero.font(.callout))
                .foregroundStyle(Aero.text.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if host.tags.isEmpty {
                // Keeps the row's height, so untagged hosts get the same card size.
                AeroTag("untagged")
                    .hidden()
                    .accessibilityHidden(true)
            } else {
                TagRow(tags: host.tags, limit: 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background { AeroHeaderWash(tint: orbTone.color) }
    }

    private var orbTone: OrbTone {
        state.orbTone(blocked: keyBlock != nil)
    }

    private var statusTitle: String {
        state.title(blocked: keyBlock != nil)
    }

    private var openSSHHelp: String {
        if canOpenSSH { return "Open a terminal tab to \(host.name)" }
        if keyBlock != nil { return "Blocked: the host key of \(host.name) changed. Review it first." }
        if state.needsHostKeyTrust { return "Trust the host key of \(host.name) first." }
        return "Terminal tabs aren't available for \(host.name) yet."
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

/// The card's status well, always two lines tall: why the host is not polled or not online
/// (with the age of its numbers), "Connecting…", or the kernel line when all is well. A held
/// host key adds the button that resolves it: Review… for a changed key, Review Key… for a
/// first key that is not trusted yet.
private struct CardStatusWell: View {
    let state: HostDisplayState
    let keyBlock: HostKeyBlock?
    let isScanningKey: Bool
    let keyScanError: String?
    let onReviewKey: () -> Void
    let onTrustKey: () -> Void

    var body: some View {
        AeroWell(tint: tint) {
            HStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    // Two lines' height whatever the message, so every card is the same size.
                    Text(verbatim: "X\nX")
                        .hidden()
                        .accessibilityHidden(true)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: symbol)
                            .foregroundStyle(tint)
                            .accessibilityHidden(true)
                        Text(text)
                            .foregroundStyle(Aero.text.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                    .help(help)
                    .accessibilityElement(children: .combine)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                accessory
            }
            .font(Aero.font(.caption, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
    }

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

    private var text: String {
        if keyBlock != nil { return "Host key changed. Not polled until you review it." }
        if state.needsHostKeyTrust { return keyScanError ?? "Not polled until you trust its host key." }
        switch state.status {
        case .loading: return state.message ?? "Connecting…"
        case .online: return state.metrics?.kernel.nilIfEmpty ?? "Online"
        case .stale: return state.message ?? "The last poll failed."
        case .offline: return state.message ?? "Not answering."
        case .unsupported: return state.message ?? "Unsupported OS."
        }
    }

    private var help: String {
        if let keyBlock { return keyBlock.helpText }
        if state.needsHostKeyTrust { return text }
        return state.lastError ?? text
    }

    private var symbol: String {
        if keyBlock != nil { return "exclamationmark.octagon.fill" }
        if state.needsHostKeyTrust { return "checkmark.shield.fill" }
        switch state.status {
        case .loading: return "hourglass"
        case .online: return "checkmark.circle.fill"
        case .stale: return "exclamationmark.triangle.fill"
        case .offline: return "bolt.horizontal.circle.fill"
        case .unsupported: return "questionmark.circle.fill"
        }
    }

    private var tint: Color {
        if keyBlock != nil { return Aero.coral }
        if state.needsHostKeyTrust { return Aero.aqua }
        switch state.status {
        case .loading, .unsupported: return Aero.neutral
        case .online: return Aero.leaf
        case .stale: return Aero.sun
        case .offline: return Aero.coral
        }
    }
}

/// Title and icon, or the icon alone on narrow cards (the title stays the accessibility label).
private struct OpenSSHLabelStyle: LabelStyle {
    let showsTitle: Bool

    func makeBody(configuration: Configuration) -> some View {
        if showsTitle {
            Label(configuration)
        } else {
            configuration.icon
                .accessibilityLabel(Text("Open SSH"))
        }
    }
}

/// A small caption + value pair on a card ("Uptime 12d 4h").
private struct CardFigure: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
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
