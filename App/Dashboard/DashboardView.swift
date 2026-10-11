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

/// "6 hosts · 2 online · 1 offline" line above the grid.
private struct DashboardSummary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let counts = model.statusCounts()
        let parts = [HostStatus.online, .stale, .offline, .unsupported, .loading].compactMap { status in
            counts[status].map { "\($0) \(status.summaryLabel)" }
        }
        let total = model.hosts.count
        Text(([total == 1 ? "1 host" : "\(total) hosts"] + parts).joined(separator: " · "))
            .font(Aero.font(.headline, weight: .medium))
            .foregroundStyle(Aero.text.secondary)
    }
}

/// A host's dashboard card: orb, name, address, tags, CPU / memory / disk gauges, uptime, load,
/// an Open SSH button and a one-line status footer.
///
/// Stale or offline hosts keep their last numbers, dimmed, with "updated Xs ago". A held host
/// key shows the red changed-key banner or the trust row instead of numbers.
struct HostCard: View {
    let host: RemoteHost
    let state: HostDisplayState
    var isSelected = false
    var canOpenSSH = false
    var onOpenSSH: () -> Void = {}
    /// Set when the host's key changed: the card shows the blocked banner.
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
        AeroCard {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let keyBlock {
                    HostKeyChangedBanner(host: host, block: keyBlock, style: .compact, onReview: onReviewKey)
                } else if state.needsHostKeyTrust {
                    HostKeyTrustRow(isScanning: isScanningKey, error: keyScanError, onReview: onTrustKey)
                }
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
                // Narrow cards (the grid's 300 pt minimum) drop the button's title, then stack.
                ViewThatFits(in: .horizontal) {
                    figuresRow(metrics, dimmed: dimmed, buttonTitle: true)
                    figuresRow(metrics, dimmed: dimmed, buttonTitle: false)
                    VStack(alignment: .leading, spacing: 10) {
                        figures(metrics, dimmed: dimmed)
                        openSSHButton(title: true)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                CardFooter(state: state, blocked: keyBlock != nil)
            }
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: Aero.radius.card, style: .continuous)
                    .strokeBorder(Aero.aqua, lineWidth: 2)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Aero.radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(host.name)
        .accessibilityValue(statusTitle)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Double-click for details")
    }

    private func figuresRow(_ metrics: MetricsSnapshot?, dimmed: Bool, buttonTitle: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            figures(metrics, dimmed: dimmed)
            Spacer(minLength: 8)
            openSSHButton(title: buttonTitle)
        }
    }

    private func figures(_ metrics: MetricsSnapshot?, dimmed: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            CardFigure(label: "Uptime", value: MetricText.uptime(metrics?.uptimeSeconds))
            CardFigure(label: "Load 1 · 5 · 15", value: MetricText.load(metrics))
        }
        .fixedSize()
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
                    .font(Aero.font(.caption, weight: .medium))
                    .foregroundStyle(Aero.text.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Text(host.connectionSummary)
                .font(Aero.font(.callout))
                .foregroundStyle(Aero.text.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !host.tags.isEmpty {
                TagRow(tags: host.tags, limit: 4)
            }
        }
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

/// The card's last line: why the host is not online (and how old its numbers are), "Connecting…",
/// or the kernel line when all is well.
private struct CardFooter: View {
    let state: HostDisplayState
    let blocked: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(Aero.text.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(state.lastError ?? text)
            Spacer(minLength: 4)
            if let since = agedSince {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("updated \(MetricText.age(of: since, now: context.date)) ago")
                        .monospacedDigit()
                        .foregroundStyle(Aero.text.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .font(Aero.font(.caption, weight: .medium))
        .accessibilityElement(children: .combine)
    }

    /// When the numbers on screen were sampled, if they are old.
    private var agedSince: Date? {
        guard state.showsOldNumbers else { return nil }
        return state.metrics?.sampledAt ?? state.lastSuccessAt
    }

    private var text: String {
        if blocked { return "Not polled until the host key is reviewed." }
        if state.needsHostKeyTrust { return "Not polled until you trust its host key." }
        switch state.status {
        case .loading: return state.message ?? "Connecting…"
        case .online: return state.metrics?.kernel.nilIfEmpty ?? "Online"
        case .stale: return state.message ?? "The last poll failed."
        case .offline: return state.message ?? "Not answering."
        case .unsupported: return state.message ?? "Unsupported OS."
        }
    }

    private var symbol: String {
        if blocked || state.needsHostKeyTrust { return "lock.shield" }
        switch state.status {
        case .loading: return "hourglass"
        case .online: return "checkmark.circle"
        case .stale: return "exclamationmark.triangle"
        case .offline: return "bolt.horizontal.circle"
        case .unsupported: return "questionmark.circle"
        }
    }

    private var tint: Color {
        if blocked { return Aero.coral }
        if state.needsHostKeyTrust { return Aero.aquaDeep }
        switch state.status {
        case .loading, .unsupported: return Aero.neutral
        case .online: return Aero.leaf
        case .stale: return Aero.sun
        case .offline: return Aero.coral
        }
    }
}

/// A card row for a host whose first key is not trusted yet: Review Key… opens the trust sheet.
private struct HostKeyTrustRow: View {
    let isScanning: Bool
    let error: String?
    let onReview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    title("Host key not trusted yet")
                    title("Key not trusted")
                }
                Spacer(minLength: 8)
                if isScanning {
                    ProgressView().controlSize(.small)
                }
                Button("Review Key…", action: onReview)
                    .buttonStyle(.aquaSecondary)
                    .controlSize(.small)
                    .disabled(isScanning)
                    .help("Show the fingerprints this host presents and trust them to start monitoring")
            }
            if let error {
                Text(error)
                    .font(Aero.font(.caption))
                    .foregroundStyle(Aero.text.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            let shape = RoundedRectangle(cornerRadius: Aero.radius.inner, style: .continuous)
            shape.fill(Aero.glass.solidFill)
            shape.fill(Aero.aqua.opacity(0.12))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Aero.radius.inner, style: .continuous)
                .strokeBorder(Aero.aqua, lineWidth: 1.5)
        }
    }

    private func title(_ text: String) -> some View {
        Label {
            Text(text)
                .font(Aero.font(.callout, weight: .semibold))
                .foregroundStyle(Aero.text.primary)
                .lineLimit(1)
        } icon: {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(Aero.aquaDeep)
        }
        .fixedSize()
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
            Text(value)
                .font(Aero.font(.callout, weight: .semibold))
                .foregroundStyle(Aero.text.primary)
                .monospacedDigit()
                .lineLimit(1)
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
