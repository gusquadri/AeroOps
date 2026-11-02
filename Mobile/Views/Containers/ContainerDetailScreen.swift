import AeroCore
import AeroTheme
import Collectors
import SwiftUI

/// A container: its state, usage and inspect summary, with logs and Stop, Restart and Delete.
/// The raw inspect JSON holds its environment, so it opens only on request.
struct ContainerDetailScreen: View {
    let containers: HostContainersModel
    let id: ContainerInfo.ID

    var body: some View {
        Group {
            if let container = containers.containers.first(where: { $0.id == id }) {
                ContainerDetail(container: container, containers: containers)
            } else {
                AeroEmptyState(systemImage: "shippingbox", title: "Container gone", message: "It is no longer on this server.")
            }
        }
        .background { SkyBackground() }
        .navigationBarTitleDisplayMode(.inline)
        .modifier(WorkloadPolling(containers: containers))
    }
}

private struct ContainerDetail: View {
    let container: ContainerInfo
    let containers: HostContainersModel
    @Environment(MobileNavigator.self) private var navigator
    @State private var inspectedState: ContainerState?

    var body: some View {
        List {
            Section {
                WorkloadFact("Status", container.status)
                WorkloadFact("Image", container.image)
                if container.hasUsage {
                    WorkloadFact("CPU", container.cpuText)
                    WorkloadFact("Memory", container.memoryText)
                }
                if !container.portsText.isEmpty { WorkloadFact("Ports", container.portsText) }
            }
            .listRowBackground(Aero.glass.fill)
            Section {
                Button("Logs", systemImage: "text.alignleft") {
                    containers.showLogs(container)
                    navigator.pushLogs(of: containers)
                }
            }
            .listRowBackground(Aero.glass.fill)
            ContainerActionItems(container: container, containers: containers)
                .listRowBackground(Aero.glass.fill)
            InspectionSection(containers: containers)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(container.name)
        .task(id: container.state) {
            guard inspectedState != container.state else { return }
            inspectedState = container.state
            containers.inspect(container)
        }
    }
}

private struct InspectionSection: View {
    let containers: HostContainersModel

    var body: some View {
        Section("Inspect") {
            if let inspection = containers.inspection {
                if let issue = inspection.issue {
                    WorkloadFact(issue.title, issue.hint ?? "")
                } else if let summary = inspection.summary {
                    facts(summary)
                    NavigationLink("Raw JSON", value: ContainersRoute.inspection(containers.hostID))
                } else {
                    ProgressView()
                }
            }
        }
        .listRowBackground(Aero.glass.fill)
    }

    @ViewBuilder
    private func facts(_ summary: DockerInspectSummary) -> some View {
        WorkloadFact("ID", String(summary.id.prefix(12)))
        WorkloadFact("Restarts", "\(summary.restartCount)" + (summary.restartPolicy.map { " (policy \($0))" } ?? ""))
        if let health = summary.healthCheck { WorkloadFact("Health check", health.rawValue) }
        if let code = summary.exitCode { WorkloadFact("Exit code", "\(code)") }
        if let started = summary.startedAt { WorkloadFact("Started", started.formatted(date: .abbreviated, time: .shortened)) }
        if let finished = summary.finishedAt { WorkloadFact("Finished", finished.formatted(date: .abbreviated, time: .shortened)) }
    }
}

/// The inspect JSON the user asked to see.
struct InspectionJSONScreen: View {
    let containers: HostContainersModel

    var body: some View {
        WorkloadTextScreen(title: containers.inspection?.name ?? "Inspect", text: containers.inspection?.json ?? "")
    }
}
