import SwiftUI

/// Every Aero component over ``SkyBackground``, laid out like the dashboard. Used by the
/// previews and by the render test that writes `build/theme-showcase.png` for visual review.
struct AeroThemeShowcase: View {
    static let size = CGSize(width: 1000, height: 700)

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            HStack(alignment: .top, spacing: 18) {
                HostCardSample(
                    name: "web-01", tone: .healthy, tags: ["prod", "eu-west"],
                    detail: "Ubuntu 24.04 · up 12 days · load 0.42",
                    cpu: 0.23, memory: 0.58, disk: 0.41
                )
                HostCardSample(
                    name: "db-02", tone: .warning, tags: ["prod"],
                    detail: "Debian 12 · up 3 days · load 7.91",
                    cpu: 0.97, memory: 0.86, disk: 0.72
                )
                HostCardSample(
                    name: "edge-pi", tone: .error, tags: ["lab"],
                    detail: "Offline · last seen 2 h ago",
                    cpu: nil, memory: nil, disk: nil
                )
            }
            HStack(alignment: .top, spacing: 18) {
                GlassSection("Pending approvals", systemImage: "hand.raised.fill") {
                    VStack(alignment: .leading, spacing: 12) {
                        approvalRow("claude-code", command: "docker restart api", host: "web-01")
                        approvalRow("cursor", command: "kubectl delete pod web-7f9c", host: "db-02")
                    }
                } accessory: {
                    AeroTag("2 pending", tone: .warning)
                }
                .frame(maxWidth: .infinity)
                GlassSection("Components", systemImage: "sparkles") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 14) {
                            ForEach(OrbTone.allCases, id: \.self) { tone in
                                StatusOrb(tone: tone, size: 22)
                            }
                            Spacer()
                            ForEach(OrbTone.allCases, id: \.self) { tone in
                                StatusOrb(tone: tone)
                            }
                        }
                        HStack(spacing: 6) {
                            AeroTag("Running", tone: .healthy)
                            AeroTag("Pending", tone: .warning)
                            AeroTag("CrashLoop", tone: .error)
                            AeroTag("Done", tone: .neutral)
                        }
                        HStack(spacing: 8) {
                            Button("Primary") {}.buttonStyle(.aqua)
                            Button("Secondary") {}.buttonStyle(.aquaSecondary)
                            Button("Off") {}.buttonStyle(.aqua).disabled(true)
                            Spacer(minLength: 0)
                            Button("Add", systemImage: "plus") {}.buttonStyle(.aqua).controlSize(.large)
                        }
                    }
                }
                .frame(width: 420)
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(width: Self.size.width, height: Self.size.height)
        .background { SkyBackground() }
        .environment(\.colorScheme, .light)
    }

    private var header: some View {
        HStack(spacing: 12) {
            StatusOrb(tone: .healthy, size: 22)
            Text("AeroOps")
                .font(Aero.font(.largeTitle, weight: .bold))
                .foregroundStyle(Aero.text.primary)
            Text("3 hosts · 1 needs attention")
                .font(Aero.font(.title3, weight: .medium))
                .foregroundStyle(Aero.text.secondary)
            Spacer()
            Button("Add Host", systemImage: "plus") {}.buttonStyle(.aquaSecondary)
            Button("Open SSH", systemImage: "terminal") {}.buttonStyle(.aqua)
        }
    }

    private func approvalRow(_ agent: String, command: String, host: String) -> some View {
        HStack(spacing: 10) {
            StatusOrb(tone: .warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(command)
                    .font(Aero.font(.callout, weight: .semibold))
                    .foregroundStyle(Aero.text.primary)
                Text("\(agent) on \(host)")
                    .font(Aero.font(.caption))
                    .foregroundStyle(Aero.text.secondary)
            }
            Spacer()
            Button("Deny", role: .destructive) {}.buttonStyle(.aqua).controlSize(.small)
            Button("Approve") {}.buttonStyle(.aqua).controlSize(.small)
        }
    }
}

/// A dashboard host card built only from Aero components.
private struct HostCardSample: View {
    let name: String
    let tone: OrbTone
    let tags: [String]
    let detail: String
    let cpu: Double?
    let memory: Double?
    let disk: Double?

    var body: some View {
        AeroCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    StatusOrb(tone: tone, size: 14)
                    Text(name)
                        .font(Aero.font(.title3, weight: .bold))
                    Spacer()
                    ForEach(tags, id: \.self) { AeroTag($0) }
                }
                Text(detail)
                    .font(Aero.font(.callout))
                    .foregroundStyle(Aero.text.secondary)
                HStack {
                    GlossyGauge(value: cpu, label: "CPU")
                    Spacer()
                    GlossyGauge(value: memory, label: "Memory")
                    Spacer()
                    GlossyGauge(value: disk, label: "Disk")
                }
                .padding(.horizontal, 6)
                HStack {
                    Button("Open SSH", systemImage: "terminal") {}
                        .buttonStyle(.aqua)
                        .disabled(tone == .error)
                    Spacer()
                    Button("Logs") {}.buttonStyle(.aquaSecondary)
                }
            }
        }
    }
}

#Preview("Showcase", traits: .fixedLayout(width: 1000, height: 700)) {
    AeroThemeShowcase()
}

#Preview("Showcase: all accessibility settings", traits: .fixedLayout(width: 1000, height: 700)) {
    AeroThemeShowcase()
        .environment(\.aeroAccessibilityOverride, .all)
}
