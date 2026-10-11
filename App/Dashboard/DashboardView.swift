import AeroCore
import AeroTheme
import SwiftUI

/// Dashboard tab: one card per host. Gauges show a dash until Phase 3 feeds live metrics into
/// each host's ``HostDisplayState``.
struct DashboardView: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 290, maximum: 420), spacing: 20, alignment: .top)]

    var body: some View {
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
                            HostCard(
                                host: host,
                                state: model.displayState(for: host.id),
                                isSelected: model.selection == host.id,
                                canOpenSSH: model.canOpenSSH(host.id),
                                onOpenSSH: { model.openSSH(host.id) }
                            )
                            .onTapGesture { model.selection = host.id }
                        }
                    }
                }
                .padding(24)
            }
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

/// A host's dashboard card: orb, name, address, tags, CPU / memory / disk gauges, uptime, load
/// and an Open SSH button (disabled until Phase 4).
struct HostCard: View {
    let host: RemoteHost
    let state: HostDisplayState
    var isSelected = false
    var canOpenSSH = false
    var onOpenSSH: () -> Void = {}

    var body: some View {
        let metrics = state.metrics
        AeroCard {
            VStack(alignment: .leading, spacing: 14) {
                header
                HStack(alignment: .top) {
                    GlossyGauge(value: metrics?.cpuPercent.map { $0 / 100 }, label: "CPU")
                    Spacer(minLength: 8)
                    GlossyGauge(value: metrics?.memUsedFraction, label: "Memory")
                    Spacer(minLength: 8)
                    GlossyGauge(value: metrics?.disk()?.usedFraction, label: "Disk")
                }
                .padding(.horizontal, 8)
                HStack(alignment: .bottom, spacing: 16) {
                    CardFigure(label: "Uptime", value: MetricText.uptime(metrics?.uptimeSeconds))
                    CardFigure(label: "Load", value: MetricText.load(metrics))
                    Spacer(minLength: 8)
                    Button("Open SSH", systemImage: "terminal", action: onOpenSSH)
                        .buttonStyle(.aqua)
                        .disabled(!canOpenSSH)
                        .help(canOpenSSH ? "Open a terminal tab to \(host.name)" : "Terminal tabs are coming in a later version")
                }
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
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusOrb(tone: state.status.orbTone, size: 14)
                Text(host.name)
                    .font(Aero.font(.title3, weight: .semibold))
                    .foregroundStyle(Aero.text.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(state.status.title)
                    .font(Aero.font(.caption, weight: .medium))
                    .foregroundStyle(Aero.text.secondary)
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
            Text(value)
                .font(Aero.font(.callout, weight: .semibold))
                .foregroundStyle(Aero.text.primary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
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
