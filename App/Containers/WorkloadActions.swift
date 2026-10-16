import AeroCore
import AeroTheme
import Collectors
import SwiftUI

/// Stop, restart and delete for container and pod rows.
///
/// Docker runs `docker stop`, `docker restart` and `docker rm -f`. Kubernetes has no stop for a
/// pod: Stop scales the pod's Deployment or StatefulSet to 0, Restart deletes the pod so its
/// controller creates a new one, and Delete deletes it. Delete always asks first, and so does a
/// pod's Stop, which stops every replica.
enum WorkloadAction: String, Hashable, Sendable {
    case stop
    case restart
    case delete
}

/// An action picked on a row, with the texts for its confirmation and its failure alert.
struct WorkloadActionRequest: Identifiable, Hashable {
    enum Target: Hashable {
        case container(ContainerInfo)
        case pod(PodInfo)
    }

    let action: WorkloadAction
    let target: Target

    var id: String { "\(action.rawValue) \(rowID)" }

    /// The row the action runs on: a container ID or `namespace/pod`.
    var rowID: String {
        switch target {
        case .container(let container): container.id
        case .pod(let pod): pod.id
        }
    }

    private var displayName: String {
        switch target {
        case .container(let container): container.name
        case .pod(let pod): pod.name
        }
    }

    var needsConfirmation: Bool {
        switch (action, target) {
        case (.delete, _), (.stop, .pod): true
        case (.stop, .container), (.restart, _): false
        }
    }

    var confirmationTitle: String {
        switch (action, target) {
        case (.stop, .pod(let pod)):
            "Stop \(pod.owner.map { "\($0.kind) “\($0.name)”" } ?? "“\(pod.name)”")?"
        case (.delete, .container(let container)):
            "Delete container “\(container.name)”?"
        case (.delete, .pod(let pod)):
            "Delete pod “\(pod.name)”?"
        default:
            ""
        }
    }

    var confirmationMessage: String {
        switch (action, target) {
        case (.stop, .pod(let pod)):
            guard let owner = pod.owner else { return "" }
            return "AeroOps scales it to 0 replicas. That stops all of its pods, not only this one, and they leave "
                + "this list. To start it again, run kubectl scale -n \(pod.namespace) "
                + "\(owner.kind.lowercased())/\(owner.name) --replicas=<count> on the host."
        case (.delete, .container):
            return "AeroOps runs docker rm -f: a running container is killed first. Changes to its files are lost; "
                + "volumes are kept. This can’t be undone."
        case (.delete, .pod(let pod)):
            guard let owner = pod.owner else { return "Nothing replaces a pod without a controller: it’s gone for good." }
            if owner.recreatesPods {
                return "Its \(owner.kind) “\(owner.name)” creates a new pod in its place. To remove it for good, "
                    + "delete or scale the \(owner.kind)."
            }
            return "Its \(owner.kind) “\(owner.name)” may not replace it."
        default:
            return ""
        }
    }

    var confirmButtonTitle: String {
        switch (action, target) {
        case (.stop, .pod): "Scale to 0"
        case (.stop, .container): "Stop"
        case (.restart, _): "Restart"
        case (.delete, _): "Delete"
        }
    }

    var failureTitle: String {
        let verb = switch action {
        case .stop: "stop"
        case .restart: "restart"
        case .delete: "delete"
        }
        return "Couldn’t \(verb) “\(displayName)”"
    }
}

/// Why an action failed, for the alert.
struct WorkloadActionFailure: Identifiable {
    let id = UUID()
    let title: String
    let issue: WorkloadIssue

    var message: String {
        [issue.title, issue.hint].compactMap(\.self).joined(separator: "\n\n")
    }
}

extension ContainerInfo {
    /// Whether Stop applies: the container is running, restarting or paused.
    var canStop: Bool {
        state == .running || state == .restarting || state == .paused
    }
}

extension PodInfo {
    /// Whether Stop applies: the pod's owner can be scaled to 0.
    var canStop: Bool { owner?.isScalable == true }
    /// Whether Restart applies: the pod's owner replaces a deleted pod.
    var canRestart: Bool { owner?.recreatesPods == true }
}

// MARK: - Menus

/// A row's Stop, Restart and Delete menu, or a spinner while one of them runs.
struct WorkloadActionsMenu<Items: View>: View {
    let busy: Bool
    @ViewBuilder let items: () -> Items

    var body: some View {
        if busy {
            ProgressView()
                .controlSize(.small)
                .help("Working…")
        } else {
            Menu {
                items()
            } label: {
                Label("Stop, Restart or Delete", systemImage: "power")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .labelStyle(.iconOnly)
            .foregroundStyle(Aero.aquaDeep)
            .fixedSize()
            .help("Stop, restart or delete")
        }
    }
}

/// Stop, Restart and Delete… for a container, in its row menu and its context menu.
struct ContainerActionItems: View {
    let container: ContainerInfo
    let containers: HostContainersModel

    var body: some View {
        let busy = containers.isBusy(container.id)
        Button("Stop", systemImage: "stop.fill") { containers.request(.stop, on: container) }
            .disabled(busy || !container.canStop)
        Button(container.canStop ? "Restart" : "Start", systemImage: "arrow.clockwise") {
            containers.request(.restart, on: container)
        }
        .disabled(busy)
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) { containers.request(.delete, on: container) }
            .disabled(busy)
    }
}

/// Stop…, Restart and Delete… for a pod, under its owner's name.
struct PodActionItems: View {
    let pod: PodInfo
    let containers: HostContainersModel

    var body: some View {
        let busy = containers.isBusy(pod.id)
        Section(ownerTitle) {
            Button(pod.canStop ? "Stop (Scale to 0)…" : "Stop", systemImage: "stop.fill") {
                containers.request(.stop, on: pod)
            }
            .disabled(busy || !pod.canStop)
            Button("Restart", systemImage: "arrow.clockwise") { containers.request(.restart, on: pod) }
                .disabled(busy || !pod.canRestart)
        }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) { containers.request(.delete, on: pod) }
            .disabled(busy)
    }

    /// The owner, or why Stop and Restart are off.
    private var ownerTitle: String {
        guard let owner = pod.owner else { return "No controller: can’t stop or restart" }
        if !owner.isScalable, !owner.recreatesPods { return "\(owner.kind) \(owner.name): can’t stop or restart" }
        if !owner.isScalable { return "\(owner.kind) \(owner.name): can’t stop" }
        return "\(owner.kind) \(owner.name)"
    }
}
