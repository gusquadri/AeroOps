import AeroCore
import SSHKit

extension HostKeyChangedBanner {
    /// The banner wired to the app's ``SSHServices``: Trust New Key replaces the pinned key and
    /// Fetch Current Key re-checks it.
    init(host: RemoteHost, block: HostKeyBlock, ssh: SSHServices) {
        self.init(
            host: host,
            block: block,
            onTrustNewKey: { try await ssh.trust(block.offered, for: host, replacingPinned: true) },
            onRecheck: { _ = try await ssh.recheckHostKey(host) }
        )
    }
}
