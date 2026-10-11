import AeroCore
import Foundation

/// Phase 3: live metrics. ``AppModel/monitoring`` does the work; these are the model-level
/// entry points views and menu commands use.
extension AppModel {
    /// Gives ``monitoring`` the per-host states and registers it after ``ssh`` (so `ssh_config`
    /// is rewritten before monitors see a host change). Called once from `init`.
    func bindMonitoring() {
        monitoring.bind { [weak self] id in self?.displayStates[id] }
        addInventoryObserver(monitoring)
    }

    /// Polls every host now (Refresh, ⌘R on the dashboard).
    func refreshAll() {
        monitoring.refreshAll()
    }

    /// Polls one host now.
    func refresh(_ id: RemoteHost.ID) {
        monitoring.refresh(id)
    }
}
