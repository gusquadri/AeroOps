import AeroCore
import AeroTheme
import SSHKit
import SwiftUI

// MARK: - Key list

/// Host keys as rows: type and size, then the SHA256 fingerprint in monospace (selectable, so
/// it can be compared with `ssh-keygen -lf` output on the server).
struct HostKeyList: View {
    let keys: [HostKey]
    var tint: Color = Aero.aqua

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(keys, id: \.self) { key in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        AeroTag(key.displayType, tint: tint)
                        if let bits = key.bits {
                            Text("\(bits) bits")
                                .font(Aero.font(.caption))
                                .foregroundStyle(Aero.text.secondary)
                        }
                    }
                    Text(key.fingerprint)
                        .font(Aero.font(.callout))
                        .monospaced()
                        .foregroundStyle(Aero.text.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

extension HostKey {
    /// "ED25519 SHA256:…" lines, for help tags.
    static func summary(_ keys: [HostKey]) -> String {
        keys.isEmpty ? "unknown" : keys.map(\.description).joined(separator: "\n")
    }
}

extension HostKeyBlock {
    /// Tooltip text: what was trusted and what the server presents now.
    var helpText: String {
        "Host key changed. AeroOps will not connect until you review it.\nTrusted:\n\(HostKey.summary(pinned))\nPresented now:\n\(HostKey.summary(offered))"
    }
}

// MARK: - First contact

/// First contact with a host: the keys it presented, for the user to trust (written to
/// AeroOps' `known_hosts`) or cancel. Nothing was logged in to yet.
struct HostKeyTrustSheet: View {
    let host: RemoteHost
    let offered: [HostKey]
    /// Pins the keys; a thrown error is shown in the sheet.
    let onTrust: () async throws -> Void
    let onCancel: () -> Void

    @State private var isTrusting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "checkmark.shield")
                    .font(Aero.font(size: 38, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Aero.aqua)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Trust this host?")
                        .font(Aero.font(.title2, weight: .semibold))
                        .foregroundStyle(Aero.text.primary)
                    Text("This is the first connection to \(host.address) on port \(host.port). Compare the fingerprints below with the server's own (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`) before trusting it.")
                        .font(Aero.font(.callout))
                        .foregroundStyle(Aero.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            AeroCard(padding: 14) {
                HostKeyList(keys: offered)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("AeroOps remembers these keys and refuses to connect if the server ever presents a different one.")
                .font(Aero.font(.caption))
                .foregroundStyle(Aero.text.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error {
                ValidationMessage(text: error)
            }

            HStack(spacing: 12) {
                if isTrusting {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.aquaSecondary)
                    .keyboardShortcut(.cancelAction)
                Button("Trust", systemImage: "checkmark.shield", action: trust)
                    .buttonStyle(.aqua)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isTrusting || offered.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background { Aero.sky.gradient.ignoresSafeArea() }
    }

    private func trust() {
        isTrusting = true
        error = nil
        Task {
            do {
                try await onTrust()
            } catch {
                self.error = error.localizedDescription
            }
            isTrusting = false
        }
    }
}

// MARK: - Changed key

/// The red "host key changed" banner. Shown in the host editor (``Style/full``), on dashboard
/// cards (``Style/compact``) and, as a tag, in the sidebar. The host stays blocked until the
/// user explicitly trusts the new key.
struct HostKeyChangedBanner: View {
    enum Style {
        /// Old and new fingerprints with Trust New Key.
        case full
        /// One line with a Review button (dashboard cards).
        case compact
    }

    @Environment(AppModel.self) private var model

    let host: RemoteHost
    let block: HostKeyBlock
    var style: Style = .full
    /// Compact style: opens the host editor.
    var onReview: () -> Void = {}

    @State private var isConfirming = false
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        Group {
            switch style {
            case .full: full
            case .compact: compact
            }
        }
        .background {
            // Opaque base so the tint reads the same over cards, forms and the sky.
            let shape = RoundedRectangle(cornerRadius: Aero.radius.inner, style: .continuous)
            shape.fill(Aero.glass.solidFill)
            shape.fill(Aero.coral.opacity(0.14))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Aero.radius.inner, style: .continuous)
                .strokeBorder(Aero.coral, lineWidth: 1.5)
        }
    }

    private var title: some View {
        Label {
            Text(style == .full ? "Host key changed: \(host.name) is blocked" : "Host key changed · blocked")
                .font(Aero.font(style == .full ? .headline : .callout, weight: .semibold))
                .foregroundStyle(Aero.text.primary)
        } icon: {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(Aero.coral)
        }
    }

    private var compact: some View {
        HStack(spacing: 8) {
            title
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Review…", action: onReview)
                .buttonStyle(.aquaSecondary)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .help(block.helpText)
    }

    private var full: some View {
        VStack(alignment: .leading, spacing: 12) {
            title
            Text("\(host.address) presented a different host key than the one you trusted. The server may have been reinstalled, or someone may be intercepting the connection. AeroOps will not connect to this host until you review the change.")
                .font(Aero.font(.callout))
                .foregroundStyle(Aero.text.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                caption("Trusted key")
                HostKeyList(keys: block.pinned, tint: Aero.neutral)
            }
            VStack(alignment: .leading, spacing: 6) {
                caption("Presented now")
                if block.offered.isEmpty {
                    Text("Not known yet: ssh stopped before AeroOps could read it.")
                        .font(Aero.font(.callout))
                        .foregroundStyle(Aero.text.secondary)
                } else {
                    HostKeyList(keys: block.offered, tint: Aero.coral)
                }
            }

            if let error {
                ValidationMessage(text: error)
            }

            HStack(spacing: 10) {
                if isWorking {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
                Button("Fetch Current Key", systemImage: "arrow.clockwise", action: recheck)
                    .buttonStyle(.aquaSecondary)
                    .disabled(isWorking)
                    .help("Scan the server again to see which key it presents now")
                Button("Trust New Key…", systemImage: "exclamationmark.shield") { isConfirming = true }
                    .buttonStyle(.aquaSecondary)
                    .disabled(isWorking || block.offered.isEmpty)
            }
        }
        .padding(14)
        .confirmationDialog("Trust the new host key for \(host.name)?", isPresented: $isConfirming) {
            Button("Trust New Key", role: .destructive, action: trustNewKey)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only do this if you know why the key changed, for example because you reinstalled the server. The old key is removed from AeroOps' known_hosts.\n\nNew: \(HostKey.summary(block.offered))")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Aero.font(.caption, weight: .semibold))
            .foregroundStyle(Aero.text.secondary)
    }

    private func trustNewKey() {
        perform { try await model.ssh.trust(block.offered, for: host, replacingPinned: true) }
    }

    private func recheck() {
        perform { _ = try await model.ssh.recheckHostKey(host) }
    }

    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        isWorking = true
        error = nil
        Task {
            do {
                try await work()
            } catch {
                self.error = error.localizedDescription
            }
            isWorking = false
        }
    }
}

// MARK: - Previews

private enum HostKeyPreviewData {
    static let host = SampleData.hosts[1]
    static let block = HostKeyBlock(
        knownHostsName: host.knownHostsName,
        pinned: [SampleHostKeys.ed25519(seed: 1)],
        offered: [SampleHostKeys.ed25519(seed: 2), SampleHostKeys.ecdsa(seed: 3)],
        detectedAt: .now
    )
}

#Preview("Trust sheet") {
    HostKeyTrustSheet(
        host: HostKeyPreviewData.host,
        offered: [SampleHostKeys.ed25519(seed: 4), SampleHostKeys.ecdsa(seed: 5)],
        onTrust: {},
        onCancel: {}
    )
}

#Preview("Changed-key banner") {
    VStack(spacing: 16) {
        HostKeyChangedBanner(host: HostKeyPreviewData.host, block: HostKeyPreviewData.block)
        HostKeyChangedBanner(host: HostKeyPreviewData.host, block: HostKeyPreviewData.block, style: .compact)
    }
    .padding(20)
    .frame(width: 540)
    .background { Aero.sky.gradient }
    .environment(AppModel.preview())
}
