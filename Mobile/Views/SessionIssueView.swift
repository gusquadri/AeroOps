import AeroCore
import AeroTheme
import SSHKit
import SwiftUI

/// Why a terminal or the file browser could not reach a host, with the way on: the trust sheet
/// for a key AeroOps has not seen (opened once by itself), the changed-key banner for a key
/// that changed, else the error and Retry.
struct SessionIssueView: View {
    let host: RemoteHost
    let error: SSHError?
    let message: String
    var retryTitle = "Retry"
    let onRetry: () -> Void

    @Environment(MobileModel.self) private var model

    init(host: RemoteHost, error: any Error, retryTitle: String = "Retry", onRetry: @escaping () -> Void) {
        self.host = host
        self.error = SSHError(underlying: error)
        message = error.localizedDescription
        self.retryTitle = retryTitle
        self.onRetry = onRetry
    }

    var body: some View {
        switch error {
        case .hostKeyUnknown:
            unknownKey
        case .hostKeyChanged:
            changedKey
        default:
            well(tint: Aero.coral, systemImage: "exclamationmark.triangle.fill", title: "Couldn’t connect to \(host.name)", message: message) {
                Button(retryTitle, systemImage: "arrow.clockwise", action: onRetry)
                    .buttonStyle(.aqua)
            }
        }
    }

    private var unknownKey: some View {
        well(
            tint: Aero.sun,
            systemImage: "key.viewfinder",
            title: "Trust \(host.name)’s host key",
            message: "AeroOps hasn’t seen this server’s key yet. Compare its fingerprint with the server’s before you trust it."
        ) {
            Button("Review Host Key", systemImage: "checkmark.shield") {
                Task { await reviewKey() }
            }
            .buttonStyle(.aqua)
            .disabled(model.scanningHostIDs.contains(host.id))
            if let scanError = model.scanErrors[host.id] {
                ValidationMessage(text: scanError)
            }
        }
        .task { await reviewKey() }
        .onChange(of: model.trustRequest == nil) { _, isClosed in
            guard isClosed else { return }
            Task { await retryIfTrusted() }
        }
    }

    @ViewBuilder
    private var changedKey: some View {
        if let block = model.hostKeyBlock(for: host) {
            HostKeyChangedBanner(
                host: host,
                block: block,
                onTrustNewKey: {
                    try await model.trust(block.offered, for: host, replacingPinned: true)
                    onRetry()
                },
                onRecheck: {
                    try await model.recheckHostKey(host)
                    if model.hostKeyBlock(for: host) == nil { onRetry() }
                }
            )
        } else {
            well(tint: Aero.coral, systemImage: "exclamationmark.octagon.fill", title: "Host key changed", message: message) {
                Button(retryTitle, systemImage: "arrow.clockwise", action: onRetry)
                    .buttonStyle(.aquaSecondary)
            }
            .task { await model.refreshHostKeyBlocks() }
        }
    }

    /// Scans the key and opens the trust sheet; a key pinned by now just retries.
    private func reviewKey() async {
        await model.requestHostKeyTrust(for: host)
        if model.trustRequest == nil { await retryIfTrusted() }
    }

    private func retryIfTrusted() async {
        if await model.isHostKeyPinned(host) { onRetry() }
    }

    private func well(
        tint: Color,
        systemImage: String,
        title: String,
        message: String,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        AeroWell(tint: tint) {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text(title)
                        .font(Aero.font(.headline, weight: .semibold))
                        .foregroundStyle(Aero.text.primary)
                } icon: {
                    Image(systemName: systemImage)
                        .foregroundStyle(tint)
                }
                Text(message)
                    .font(Aero.font(.callout))
                    .foregroundStyle(Aero.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension SSHError {
    /// The SSH error behind `error`: itself, or why an SFTP session ended.
    init?(underlying error: any Error) {
        switch error {
        case let error as SSHError: self = error
        case SFTPError.disconnected(let error): self = error
        default: return nil
        }
    }
}
