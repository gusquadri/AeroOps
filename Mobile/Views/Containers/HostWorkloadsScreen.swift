import AeroCore
import AeroTheme
import Collectors
import SwiftUI

/// One host's containers and pods as phone-sized rows: tap for details, swipe for logs and
/// Stop or Restart, press and hold for everything.
struct HostWorkloadsScreen: View {
    @Bindable var containers: HostContainersModel

    var body: some View {
        content
            .background { SkyBackground() }
            .navigationTitle(containers.host?.name ?? "Containers")
            .navigationBarTitleDisplayMode(.inline)
            .tabSearchable(text: searchText, placement: .navigationBarDrawer(displayMode: .always))
            .tabToolbar {
                ToolbarItem(placement: .primaryAction) { filterMenu }
            }
            .safeAreaInset(edge: .top) { sectionPicker }
            .refreshable { await containers.refresh(reprobe: true) }
            .modifier(WorkloadPolling(containers: containers))
    }

    @ViewBuilder
    private var content: some View {
        if let issue = containers.connectionIssue {
            WorkloadIssuePanel(issue: issue, containers: containers)
        } else if containers.capabilities == nil {
            ProgressView("Connecting…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch containers.visibleSection {
            case .docker: DockerRows(containers: containers)
            case .kubernetes: PodRows(containers: containers)
            case nil: nothingFound
            }
        }
    }

    private var nothingFound: some View {
        AeroEmptyState(
            systemImage: "shippingbox",
            title: "No Docker or Kubernetes",
            message: "AeroOps looked for docker, podman, kubectl and k3s on this server."
        ) {
            Button("Check Again", systemImage: "arrow.clockwise") {
                Task { await containers.refresh(reprobe: true) }
            }
            .buttonStyle(.aqua)
        }
    }

    @ViewBuilder
    private var sectionPicker: some View {
        if containers.availableSections.count > 1 {
            Picker("Section", selection: Binding(get: { containers.visibleSection }, set: { containers.section = $0 })) {
                ForEach(containers.availableSections) { Text($0.title).tag($0 as HostContainersModel.Section?) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private var searchText: Binding<String> {
        containers.visibleSection == .kubernetes ? $containers.podSearch : $containers.dockerSearch
    }

    @ViewBuilder
    private var filterMenu: some View {
        Menu("Filter", systemImage: "line.3.horizontal.decrease.circle") {
            if containers.visibleSection == .kubernetes {
                Picker("Namespace", selection: $containers.namespace) {
                    Text("All Namespaces").tag(String?.none)
                    ForEach(containers.namespaces, id: \.self) { Text($0).tag(String?.some($0)) }
                }
            } else {
                Toggle("Show Stopped", systemImage: "stop.circle", isOn: $containers.showStopped)
            }
        }
    }
}

/// Why a section or the whole host can't be read, with the way on.
struct WorkloadIssuePanel: View {
    let issue: WorkloadIssue
    let containers: HostContainersModel
    @Environment(MobileModel.self) private var model
    @State private var isEditingHost = false

    var body: some View {
        AeroEmptyState(systemImage: "exclamationmark.triangle", title: issue.title, message: issue.hint ?? "") {
            Button("Retry", systemImage: "arrow.clockwise") {
                Task { await containers.refresh(reprobe: true) }
            }
            .buttonStyle(.aqua)
            if issue.kind == .access, let host = containers.host {
                Button("Review Host Key", systemImage: "checkmark.shield") {
                    Task { await model.requestHostKeyTrust(for: host) }
                }
                .buttonStyle(.aquaSecondary)
            }
            if issue.offersHostEditor {
                Button("Edit Host", systemImage: "slider.horizontal.3") { isEditingHost = true }
                    .buttonStyle(.aquaSecondary)
            }
        }
        .sheet(isPresented: $isEditingHost) {
            HostEditorScreen(request: .edit(containers.hostID))
        }
    }
}

private struct DockerRows: View {
    let containers: HostContainersModel
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        if containers.containers.isEmpty, let issue = containers.dockerIssue {
            WorkloadIssuePanel(issue: issue, containers: containers)
        } else if !containers.dockerLoaded {
            ProgressView("Loading containers…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if containers.filteredContainers.isEmpty {
            AeroEmptyState(systemImage: "shippingbox", title: "No containers", message: "Nothing to show. Stopped containers are in Filter.")
        } else {
            List(containers.filteredContainers) { row($0) }
                .scrollContentBackground(.hidden)
        }
    }

    private func row(_ container: ContainerInfo) -> some View {
        NavigationLink(value: ContainersRoute.container(containers.hostID, container.id)) {
            ContainerRow(container: container, isBusy: containers.isBusy(container.id))
        }
        .swipeActions(edge: .leading) {
            Button("Logs", systemImage: "text.alignleft") {
                containers.showLogs(container)
                navigator.pushLogs(of: containers)
            }
            .tint(Aero.aquaDeep)
        }
        .swipeActions(edge: .trailing) {
            Button(container.canStop ? "Restart" : "Start", systemImage: "arrow.clockwise") {
                containers.request(.restart, on: container)
            }
            .tint(Aero.leaf)
            if container.canStop {
                Button("Stop", systemImage: "stop.fill") { containers.request(.stop, on: container) }
                    .tint(Aero.coral)
            }
        }
        .contextMenu { ContainerActionItems(container: container, containers: containers) }
        .disabled(containers.isBusy(container.id))
        .listRowBackground(Aero.glass.fill)
    }
}

private struct ContainerRow: View {
    let container: ContainerInfo
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 12) {
            StatusOrb(tone: container.health.workloadTone, size: 10)
            VStack(alignment: .leading, spacing: 3) {
                WorkloadRowTitle(text: container.name)
                WorkloadRowDetail(text: container.image)
                WorkloadRowDetail(text: container.hasUsage ? "\(container.cpuText) · \(container.memoryText)" : container.status)
            }
            Spacer(minLength: 8)
            if isBusy {
                ProgressView()
            } else {
                AeroTag(container.state.rawValue.capitalized, tone: container.health.workloadTone)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct PodRows: View {
    let containers: HostContainersModel
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        if containers.pods.isEmpty, let issue = containers.podsIssue {
            WorkloadIssuePanel(issue: issue, containers: containers)
        } else if !containers.podsLoaded {
            ProgressView("Loading pods…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if containers.filteredPods.isEmpty {
            AeroEmptyState(systemImage: "helm", title: "No pods", message: "Nothing to show in this namespace.")
        } else {
            List(containers.filteredPods) { row($0) }
                .scrollContentBackground(.hidden)
        }
    }

    private func row(_ pod: PodInfo) -> some View {
        NavigationLink(value: ContainersRoute.pod(containers.hostID, pod.id)) {
            PodRow(pod: pod, isBusy: containers.isBusy(pod.id))
        }
        .swipeActions(edge: .leading) {
            Button("Logs", systemImage: "text.alignleft") {
                containers.showLogs(pod)
                navigator.pushLogs(of: containers)
            }
            .tint(Aero.aquaDeep)
        }
        .swipeActions(edge: .trailing) {
            if pod.canRestart {
                Button("Restart", systemImage: "arrow.clockwise") { containers.request(.restart, on: pod) }
                    .tint(Aero.leaf)
            }
        }
        .contextMenu { PodActionItems(pod: pod, containers: containers) }
        .disabled(containers.isBusy(pod.id))
        .listRowBackground(Aero.glass.fill)
    }
}

private struct PodRow: View {
    let pod: PodInfo
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 12) {
            StatusOrb(tone: pod.health.workloadTone, size: 10)
            VStack(alignment: .leading, spacing: 3) {
                WorkloadRowTitle(text: pod.name)
                WorkloadRowDetail(text: "\(pod.namespace) · \(pod.readyCount)/\(pod.containerCount) ready")
                HStack(spacing: 6) {
                    AeroTag(pod.displayStatus, tone: pod.health.workloadTone)
                    if pod.restarts > 0 {
                        AeroTag("\(pod.restarts)", systemImage: "arrow.triangle.2.circlepath", tint: Aero.coral)
                    }
                }
            }
            Spacer(minLength: 8)
            if isBusy { ProgressView() }
        }
        .padding(.vertical, 2)
    }
}

private struct WorkloadRowTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Aero.font(.headline))
            .foregroundStyle(Aero.text.primary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

private struct WorkloadRowDetail: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Aero.font(.caption))
            .foregroundStyle(Aero.text.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.middle)
    }
}
