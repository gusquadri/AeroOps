import AeroCore
import AeroTheme
import Collectors
import SwiftUI

/// A pod: its state, containers with their logs, events (warnings first), `describe`, and Stop,
/// Restart and Delete.
struct PodDetailScreen: View {
    let containers: HostContainersModel
    let id: PodInfo.ID

    var body: some View {
        Group {
            if let pod = containers.pods.first(where: { $0.id == id }) {
                PodDetail(pod: pod, containers: containers)
            } else {
                AeroEmptyState(systemImage: "helm", title: "Pod gone", message: "It was deleted or replaced by a new one.")
            }
        }
        .background { SkyBackground() }
        .navigationBarTitleDisplayMode(.inline)
        .modifier(WorkloadPolling(containers: containers))
    }
}

private struct PodDetail: View {
    let pod: PodInfo
    let containers: HostContainersModel
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        List {
            Section {
                WorkloadFact("Status", pod.displayStatus)
                WorkloadFact("Namespace", pod.namespace)
                WorkloadFact("Ready", "\(pod.readyCount)/\(pod.containerCount)")
                WorkloadFact("Restarts", "\(pod.restarts)")
                if let node = pod.nodeName { WorkloadFact("Node", node) }
                if pod.hasUsage {
                    WorkloadFact("CPU", pod.cpuText)
                    WorkloadFact("Memory", pod.memoryText)
                }
            }
            .listRowBackground(Aero.glass.fill)
            logs
            PodActionItems(pod: pod, containers: containers)
                .listRowBackground(Aero.glass.fill)
            if let detail = containers.podDetail {
                PodEventsSection(detail: detail, hostID: containers.hostID)
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(pod.name)
        .refreshable { containers.reloadPodDetail() }
        .onAppear { containers.selectedPodID = pod.id }
    }

    private var logs: some View {
        Section("Logs") {
            ForEach(pod.containers, id: \.name) { container in
                Button(container.name, systemImage: "text.alignleft") { open(container.name, previous: false) }
                if container.hasPreviousInstance {
                    Button("\(container.name), before last restart", systemImage: "clock.arrow.circlepath") {
                        open(container.name, previous: true)
                    }
                }
            }
        }
        .listRowBackground(Aero.glass.fill)
    }

    private func open(_ container: String, previous: Bool) {
        containers.showLogs(pod, container: container, previous: previous)
        navigator.pushLogs(of: containers)
    }
}

private struct PodEventsSection: View {
    let detail: PodDetailModel
    let hostID: RemoteHost.ID

    var body: some View {
        Section("Events") {
            if let issue = detail.eventsIssue {
                WorkloadFact(issue.title, issue.hint ?? "")
            } else if detail.sortedEvents.isEmpty {
                Text(detail.isLoading ? "Loading…" : "No recent events")
                    .font(Aero.font(.callout))
                    .foregroundStyle(Aero.text.secondary)
            }
            ForEach(detail.sortedEvents) { EventRow(event: $0) }
            NavigationLink("Describe", value: ContainersRoute.describe(hostID))
        }
        .listRowBackground(Aero.glass.fill)
    }
}

private struct EventRow: View {
    let event: PodEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                StatusOrb(tone: event.isWarning ? .warning : .neutral, size: 8)
                Text(event.count > 1 ? "\(event.reason) ×\(event.count)" : event.reason)
                    .font(Aero.font(.callout, weight: .semibold))
                    .foregroundStyle(Aero.text.primary)
            }
            Text(event.message)
                .font(Aero.font(.caption))
                .foregroundStyle(Aero.text.secondary)
        }
    }
}

/// `kubectl describe` for the open pod.
struct PodDescribeScreen: View {
    let containers: HostContainersModel

    var body: some View {
        if let issue = containers.podDetail?.describeIssue {
            AeroEmptyState(systemImage: "exclamationmark.triangle", title: issue.title, message: issue.hint ?? "")
                .background { SkyBackground() }
        } else {
            WorkloadTextScreen(title: containers.podDetail?.name ?? "Describe", text: containers.podDetail?.describe ?? "")
        }
    }
}
