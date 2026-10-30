import AeroCore
import Collectors
import Foundation

extension AppModel {
    /// A model over a store in memory, filled with `hosts`.
    /// With `statuses`, host *i* gets `statuses[i % count]`; with `withMetrics`, online hosts get
    /// a sample snapshot. For previews only.
    static func preview(
        hosts: [RemoteHost] = SampleData.hosts,
        statuses: [HostStatus] = SampleData.statuses,
        withMetrics: Bool = false
    ) -> AppModel {
        let model = AppModel(hostStore: .inMemory(), connectionTester: SimulatedConnectionTester(delay: .seconds(1)))
        for host in hosts {
            try? model.addHost(host)
        }
        model.selection = nil
        model.applySampleStatuses(statuses, withMetrics: withMetrics)
        return model
    }

    /// Gives the hosts ``SampleData/liveUpdates(for:now:)``, as if their monitors had reported:
    /// every card state with numbers. Used by previews and the DEBUG demo option.
    func applySampleLiveStates() {
        for update in SampleData.liveUpdates(for: hosts) {
            displayStates[update.hostID]?.apply(update)
        }
    }

    /// Gives host *i* status `statuses[i % count]`, except hosts with monitoring off. Used by
    /// previews and the DEBUG demo option.
    func applySampleStatuses(_ statuses: [HostStatus] = SampleData.statuses, withMetrics: Bool = false) {
        guard !statuses.isEmpty else { return }
        for (index, host) in hosts.enumerated() where host.monitored {
            let status = statuses[index % statuses.count]
            let metrics = withMetrics && status == .online
                ? SampleData.metrics(cpu: Double(15 + index * 17), memory: 0.35 + Double(index) * 0.1, disk: 0.3 + Double(index) * 0.12)
                : nil
            updateState(of: host.id, status: status, metrics: metrics, message: nil)
        }
    }
}
