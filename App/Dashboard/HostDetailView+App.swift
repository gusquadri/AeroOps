import AeroCore
import SSHKit

extension HostDetailView {
    /// The detail panel wired to the app: Refresh polls through ``MonitorService``, the
    /// changed-key banner goes through ``SSHServices``.
    init(host: RemoteHost, state: HostDisplayState, keyBlock: HostKeyBlock?, model: AppModel) {
        let ssh = model.ssh
        self.init(
            host: host,
            state: state,
            keyBlock: keyBlock,
            onRefresh: { model.refresh(host.id) },
            onTrustNewKey: { try await ssh.trust(keyBlock?.offered ?? [], for: host, replacingPinned: true) },
            onRecheckKey: { _ = try await ssh.recheckHostKey(host) }
        )
    }
}
