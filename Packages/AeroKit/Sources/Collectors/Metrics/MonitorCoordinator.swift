import AeroCore
import Foundation
import SSHKit

/// Keeps one ``HostMonitor`` per host in the inventory and merges their updates into one stream.
///
/// It is a `@MainActor` class rather than an actor because everything that drives it lives on
/// the main actor and calls synchronously: the inventory observer (``setHosts(_:)``), sleep and
/// wake notifications and scene phase (``setActivity(_:)``), and buttons (``refresh(_:)``).
/// Synchronous calls apply in call order, with no hop that could reorder a host-list change and
/// an activity change. It does no I/O itself (each monitor polls and parses in its own actor),
/// so the main-actor cost is a dictionary diff per call.
@MainActor
public final class MonitorCoordinator {
    /// Builds a monitor for a host in the given activity (not started yet).
    public typealias MonitorFactory = @MainActor (RemoteHost, MonitorActivity) -> HostMonitor

    /// Updates from every monitor, in arrival order. Single consumer; finishes after ``shutdown()``.
    public let updates: AsyncStream<HostMonitorUpdate>

    /// The activity applied to every monitor, including ones added later.
    public private(set) var activity: MonitorActivity

    private let makeMonitor: MonitorFactory
    private let continuation: AsyncStream<HostMonitorUpdate>.Continuation
    private var entries: [RemoteHost.ID: Entry] = [:]
    private var latest: [RemoteHost.ID: HostMonitorUpdate] = [:]
    private var stopping: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var isShutDown = false

    private struct Entry {
        var host: RemoteHost
        let monitor: HostMonitor
        let forwarder: Task<Void, Never>
    }

    /// - Parameter makeMonitor: creates monitors; tests inject fakes here.
    public init(activity: MonitorActivity = .visible, makeMonitor: @escaping MonitorFactory) {
        self.activity = activity
        self.makeMonitor = makeMonitor
        (updates, continuation) = AsyncStream.makeStream(of: HostMonitorUpdate.self, bufferingPolicy: .bufferingNewest(256))
    }

    /// Monitors that poll through `runner` (normally the app's `SSHRunner`) and check host keys
    /// against `hostKeys` (share the runner's store).
    public convenience init(
        runner: any HostCommandRunning,
        hostKeys: HostKeyStore? = nil,
        configuration: HostMonitorConfiguration = .standard,
        clock: any MonitorClock = SystemMonitorClock(),
        activity: MonitorActivity = .visible
    ) {
        self.init(activity: activity) { host, activity in
            HostMonitor(host: host, runner: runner, hostKeys: hostKeys, configuration: configuration, clock: clock, activity: activity)
        }
    }

    // MARK: - Hosts

    /// The hosts being monitored.
    public var monitoredHostIDs: Set<RemoteHost.ID> { Set(entries.keys) }

    /// The monitor for a host, if it is monitored.
    public func monitor(for id: RemoteHost.ID) -> HostMonitor? { entries[id]?.monitor }

    /// The latest update received for a host.
    public func latestUpdate(for id: RemoteHost.ID) -> HostMonitorUpdate? { latest[id] }

    /// Matches the monitors to `hosts`: starts monitors for new hosts, stops those for removed
    /// hosts, and replaces a monitor whose address, port, user or key changed (its previous
    /// sample and status belong to the old endpoint). Other edits (name, tags) only update the
    /// stored host.
    ///
    /// Call it after `SSHConfigWriter` has written the new hosts, so new monitors connect with
    /// the new settings.
    public func setHosts(_ hosts: [RemoteHost]) {
        guard !isShutDown else { return }
        var wanted: [RemoteHost.ID: RemoteHost] = [:]
        for host in hosts { wanted[host.id] = host }

        for (id, entry) in entries where wanted[id] == nil {
            remove(id, entry)
            latest[id] = nil
        }
        for host in hosts {
            if let entry = entries[host.id] {
                if Self.needsRestart(entry.host, host) {
                    remove(host.id, entry)
                    latest[host.id] = nil
                    add(host)
                } else {
                    entries[host.id]?.host = host
                }
            } else if entries[host.id] == nil {
                add(host)
            }
        }
    }

    /// Sets every monitor's polling mode: ``MonitorActivity/paused`` while the Mac sleeps,
    /// ``MonitorActivity/visible`` while the dashboard shows, ``MonitorActivity/background`` otherwise.
    public func setActivity(_ activity: MonitorActivity) {
        guard !isShutDown, activity != self.activity else { return }
        self.activity = activity
        for entry in entries.values {
            entry.monitor.setActivity(activity)
        }
    }

    /// Polls one host now (also after its host key was trusted or replaced).
    public func refresh(_ id: RemoteHost.ID) {
        entries[id]?.monitor.refresh()
    }

    /// Polls every host now.
    public func refreshAll() {
        for entry in entries.values {
            entry.monitor.refresh()
        }
    }

    /// Stops every monitor, waits for running polls to end, and finishes ``updates``.
    public func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        for (id, entry) in entries {
            remove(id, entry)
        }
        latest.removeAll()
        let pending = Array(stopping.values)
        for task in pending {
            await task.value
        }
        stopping.removeAll()
        continuation.finish()
    }

    // MARK: - Private

    private static func needsRestart(_ old: RemoteHost, _ new: RemoteHost) -> Bool {
        old.address != new.address || old.port != new.port || old.user != new.user || old.keyId != new.keyId
    }

    private func add(_ host: RemoteHost) {
        let monitor = makeMonitor(host, activity)
        let id = ObjectIdentifier(monitor)
        let stream = monitor.updates
        let forwarder = Task { [weak self] in
            for await update in stream {
                guard let self else { return }
                self.receive(update, from: id)
            }
        }
        entries[host.id] = Entry(host: host, monitor: monitor, forwarder: forwarder)
        Task { await monitor.start() }
    }

    private func remove(_ hostID: RemoteHost.ID, _ entry: Entry) {
        entries[hostID] = nil
        entry.forwarder.cancel()
        let monitor = entry.monitor
        let key = ObjectIdentifier(monitor)
        stopping[key] = Task { [weak self] in
            await monitor.stop()
            self?.stopping[key] = nil
        }
    }

    private func receive(_ update: HostMonitorUpdate, from monitorID: ObjectIdentifier) {
        guard !isShutDown, let entry = entries[update.hostID], ObjectIdentifier(entry.monitor) == monitorID else { return }
        latest[update.hostID] = update
        continuation.yield(update)
    }
}
