import AeroCore
import AeroTheme
import Collectors
import SSHKit
import SwiftUI

/// Everything the last poll of one host returned: status and last error, system (distribution,
/// kernel, CPUs, uptime, load), memory and swap, and every mounted filesystem. Shown in the Mac
/// dashboard's inspector for the selected host, and as the iOS app's host screen.
///
/// df's portable output (`df -Pk`) has no filesystem type, so mounts show their device instead.
struct HostDetailView: View {
    /// Old numbers are dimmed less than on a card: the panel is for reading them.
    static let oldNumbersOpacity = 0.6

    let host: RemoteHost
    let state: HostDisplayState
    var keyBlock: HostKeyBlock?
    /// Polls the host now.
    var onRefresh: () -> Void = {}
    /// The changed-key banner's Trust New Key and Fetch Current Key (see ``HostKeyChangedBanner``).
    var onTrustNewKey: () async throws -> Void = {}
    var onRecheckKey: () async throws -> Void = {}
    /// Open a terminal or the file browser for the host (the iOS host screen; the Mac has them
    /// on the card). `nil` hides the button.
    var onOpenTerminal: (() -> Void)?
    var onBrowseFiles: (() -> Void)?

    var body: some View {
        let metrics = state.metrics
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if onOpenTerminal != nil || onBrowseFiles != nil {
                    sessionButtons
                }
                if let keyBlock {
                    HostKeyChangedBanner(host: host, block: keyBlock, onTrustNewKey: onTrustNewKey, onRecheck: onRecheckKey)
                }
                statusSection(metrics)
                Group {
                    systemSection(metrics)
                    memorySection(metrics)
                    disksSection(metrics)
                }
                .opacity(state.showsOldNumbers ? Self.oldNumbersOpacity : 1)
            }
            .padding(16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background { SkyBackground() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            StatusBubble(tone: state.orbTone(blocked: keyBlock != nil), logo: state.systemLogo, size: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(host.name)
                    .font(Aero.font(.title2, weight: .semibold))
                    .foregroundStyle(Aero.text.primary)
                    .lineLimit(1)
                Text(host.connectionSummary)
                    .font(Aero.font(.callout))
                    .foregroundStyle(Aero.text.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button("Refresh", systemImage: "arrow.clockwise", action: onRefresh)
                .labelStyle(.iconOnly)
                .buttonStyle(.aquaSecondary)
                .controlSize(.small)
                .disabled(!host.monitored)
                .help(host.monitored ? "Poll \(host.name) now" : "Monitoring is off for \(host.name)")
        }
    }

    private var sessionButtons: some View {
        HStack(spacing: 12) {
            if let onOpenTerminal {
                Button(action: onOpenTerminal) {
                    Label("Terminal", systemImage: "terminal")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.aqua)
            }
            if let onBrowseFiles {
                Button(action: onBrowseFiles) {
                    Label("Files", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.aquaSecondary)
            }
        }
        .disabled(keyBlock != nil)
    }

    private func statusSection(_ metrics: MetricsSnapshot?) -> some View {
        GlassSection("Status", systemImage: "waveform.path.ecg") {
            VStack(alignment: .leading, spacing: 10) {
                DetailRow("State", state.title(blocked: keyBlock != nil))
                DetailRow("Last sample") {
                    if let sampled = metrics?.sampledAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("\(sampled.formatted(date: .omitted, time: .standard)) · \(MetricText.age(of: sampled, now: context.date)) ago")
                                .monospacedDigit()
                        }
                    } else {
                        Text(MetricText.missing)
                    }
                }
                if let lastSuccess = state.lastSuccessAt, abs(lastSuccess.timeIntervalSince(metrics?.sampledAt ?? .distantPast)) >= 1 {
                    DetailRow("Last answer", lastSuccess.formatted(date: .omitted, time: .standard))
                }
                if state.consecutiveFailures > 0 {
                    DetailRow("Failed polls", "\(state.consecutiveFailures) in a row")
                }
                if let error = state.lastError {
                    DetailRow("Last error", error)
                } else if let message = state.message {
                    DetailRow("Note", message)
                }
            }
        }
    }

    private func systemSection(_ metrics: MetricsSnapshot?) -> some View {
        GlassSection("System", systemImage: "cpu") {
            VStack(alignment: .leading, spacing: 10) {
                DetailRow("Hostname", metrics?.hostname.nilIfEmpty ?? MetricText.missing)
                DetailRow("OS", metrics?.os?.displayName ?? state.systemLogo?.title ?? MetricText.missing)
                DetailRow("Kernel", metrics?.kernel.nilIfEmpty ?? state.unsupportedSystem ?? MetricText.missing)
                DetailRow("CPUs", metrics?.cpuCount.map(String.init) ?? MetricText.missing)
                DetailRow("CPU use", metrics.map { MetricText.percent($0.cpuPercent.map { $0 / 100 }) } ?? MetricText.missing)
                DetailRow("Uptime", MetricText.uptime(metrics?.uptimeSeconds))
                DetailRow("Load 1 · 5 · 15 min", MetricText.load(metrics))
            }
        }
    }

    private func memorySection(_ metrics: MetricsSnapshot?) -> some View {
        GlassSection("Memory", systemImage: "memorychip") {
            VStack(alignment: .leading, spacing: 12) {
                UsageRow(
                    title: "Memory",
                    detail: nil,
                    usage: metrics.map { MetricText.usage($0.memUsedBytes, of: $0.memTotalBytes) } ?? MetricText.missing,
                    fraction: metrics?.memUsedFraction
                )
                if let metrics, let swapTotal = metrics.swapTotalBytes {
                    if swapTotal > 0 {
                        UsageRow(
                            title: "Swap",
                            detail: nil,
                            usage: MetricText.usage(metrics.swapUsedBytes, of: swapTotal),
                            fraction: metrics.swapUsedFraction
                        )
                    } else {
                        DetailRow("Swap", "None")
                    }
                } else {
                    DetailRow("Swap", MetricText.missing)
                }
            }
        }
    }

    private func disksSection(_ metrics: MetricsSnapshot?) -> some View {
        let disks = (metrics?.disks ?? []).sorted { $0.mount < $1.mount }
        return GlassSection("Disks", systemImage: "internaldrive") {
            VStack(alignment: .leading, spacing: 12) {
                if disks.isEmpty {
                    Text(metrics == nil ? "No sample yet." : "No filesystems reported.")
                        .font(Aero.font(.callout))
                        .foregroundStyle(Aero.text.secondary)
                } else {
                    ForEach(disks) { disk in
                        UsageRow(
                            title: disk.mount,
                            detail: disk.device,
                            usage: MetricText.usage(disk.usedBytes, of: disk.totalBytes),
                            fraction: disk.usedFraction
                        )
                    }
                }
            }
        } accessory: {
            if !disks.isEmpty {
                AeroTag("\(disks.count)", tint: Aero.neutral)
            }
        }
    }
}

/// A label on the left and a value on the right, wrapping when long (errors, kernel lines).
private struct DetailRow<Value: View>: View {
    let label: String
    let value: Value

    init(_ label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(Aero.font(.callout, weight: .medium))
                .foregroundStyle(Aero.text.secondary)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 8)
            value
                .font(Aero.font(.callout, weight: .semibold))
                .foregroundStyle(Aero.text.primary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

extension DetailRow where Value == Text {
    init(_ label: String, _ value: String) {
        self.init(label) { Text(value) }
    }
}

/// A mount or memory line: name (and device), "used of total", percentage and a bar.
private struct UsageRow: View {
    let title: String
    let detail: String?
    let usage: String
    let fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(Aero.font(.callout, weight: .semibold))
                    .foregroundStyle(Aero.text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(title)
                Spacer(minLength: 8)
                Text(MetricText.percent(fraction))
                    .font(Aero.font(.callout, weight: .bold))
                    .foregroundStyle(Aero.text.primary)
                    .monospacedDigit()
            }
            UsageBar(fraction: fraction)
            HStack(spacing: 8) {
                if let detail {
                    Text(detail)
                        .font(Aero.monospacedFont(.caption))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(detail)
                }
                Spacer(minLength: 8)
                Text(usage)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(Aero.font(.caption))
            .foregroundStyle(Aero.text.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(MetricText.percent(fraction)), \(usage)")
    }
}

/// A thin glass capsule filled to `fraction`, coloured like ``GlossyGauge`` (sun from 80%,
/// coral from 95%).
private struct UsageBar: View {
    let fraction: Double?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Aero.text.primary.opacity(0.10))
                Capsule().strokeBorder(Aero.text.primary.opacity(0.08), lineWidth: 0.5)
                if let value {
                    Capsule()
                        .fill(LinearGradient(colors: colors(value), startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(proxy.size.height, proxy.size.width * value))
                        .overlay(alignment: .top) {
                            Capsule()
                                .fill(Aero.glass.rimTop.opacity(0.6))
                                .frame(height: proxy.size.height / 2)
                                .padding(.horizontal, 2)
                                .padding(.top, 1)
                        }
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }

    private var value: Double? {
        guard let fraction, fraction.isFinite else { return nil }
        return min(max(fraction, 0), 1)
    }

    private func colors(_ value: Double) -> [Color] {
        if value >= 0.95 { return [Aero.sun, Aero.coral] }
        if value >= 0.8 { return [Aero.leaf, Aero.sun] }
        return [Aero.leaf, Aero.aqua]
    }
}

#Preview("Host detail") {
    let host = SampleData.hosts[0]
    let state = HostDisplayState(hostID: host.id)
    state.apply(SampleData.liveUpdates(for: [host])[0])
    return HostDetailView(host: host, state: state)
        .frame(width: 360, height: 800)
}
