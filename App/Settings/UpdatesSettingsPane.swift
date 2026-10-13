import AeroTheme
import SwiftUI

/// Settings › Updates: Sparkle's automatic checks (on by default), automatic downloads and a
/// manual check.
///
/// Builds without an update feed (every development build) show why updates are off and offer
/// no controls; see ``UpdateService``.
struct UpdatesSettingsPane: View {
    @Environment(\.updateService) private var updates

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                GlassSection("Software updates", systemImage: "arrow.triangle.2.circlepath") {
                    content
                } accessory: {
                    AeroTag(statusTitle, tone: statusTone)
                }
            }
            .padding(20)
        }
        .background { Aero.sky.gradient.ignoresSafeArea() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Updates")
                .font(Aero.font(.title2, weight: .semibold))
                .foregroundStyle(Aero.text.primary)
            Text("AeroOps checks GitHub for new versions every hour and asks before installing one. Updates are signed and verified before they are installed.")
                .font(Aero.font(.callout))
                .foregroundStyle(Aero.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let updates, updates.status == .running {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(get: { updates.automaticallyChecks }, set: { updates.setAutomaticallyChecks($0) })) {
                    Text("Check for updates automatically")
                        .font(Aero.font(.callout, weight: .medium))
                        .foregroundStyle(Aero.text.primary)
                    Text("Every hour AeroOps downloads the update feed. Nothing is sent but the request itself.")
                        .font(Aero.font(.caption))
                        .foregroundStyle(Aero.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.switch)

                Toggle(isOn: Binding(get: { updates.automaticallyDownloads }, set: { updates.setAutomaticallyDownloads($0) })) {
                    Text("Download and install updates automatically")
                        .font(Aero.font(.callout, weight: .medium))
                        .foregroundStyle(Aero.text.primary)
                    Text("The update is installed when you quit AeroOps.")
                        .font(Aero.font(.caption))
                        .foregroundStyle(Aero.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.switch)
                .disabled(!updates.allowsAutomaticDownloads)

                HStack(spacing: 12) {
                    Button("Check for Updates…", systemImage: "arrow.down.circle") { updates.checkForUpdates() }
                        .buttonStyle(.aqua)
                        .disabled(!updates.canCheckForUpdates)
                    Text(lastCheckText(updates.lastCheckDate))
                        .font(Aero.font(.caption))
                        .foregroundStyle(Aero.text.secondary)
                }
            }
        } else {
            Text(unavailableMessage)
                .font(Aero.font(.callout))
                .foregroundStyle(Aero.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var statusTitle: String {
        switch updates?.status ?? .notConfigured {
        case .running: "On"
        case .idle: "Starting"
        case .notConfigured: "Not in this build"
        case .failed: "Error"
        }
    }

    private var statusTone: OrbTone {
        switch updates?.status ?? .notConfigured {
        case .running: .healthy
        case .idle, .notConfigured: .neutral
        case .failed: .error
        }
    }

    private var unavailableMessage: String {
        switch updates?.status ?? .notConfigured {
        case .failed(let message):
            "The updater could not start: \(message)"
        case .idle:
            "The updater is starting."
        case .notConfigured, .running:
            "This build has no update feed, so it never checks for updates. Release builds get one when they are signed for distribution."
        }
    }

    private func lastCheckText(_ date: Date?) -> String {
        guard let date else { return "Not checked yet" }
        return "Last checked \(date.formatted(.relative(presentation: .named)))"
    }
}

#Preview("Updates, not configured") {
    UpdatesSettingsPane()
        .frame(width: 780, height: 600)
}
