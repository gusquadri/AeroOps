import AeroCore
import AeroTheme
import SwiftUI

/// Docker containers: running/all filter, search, and the table with per-row actions.
struct DockerSection: View {
    let host: RemoteHost
    @Bindable var containers: HostContainersModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            if let issue = containers.dockerIssue {
                WorkloadIssueCard(
                    issue: issue, hostID: host.id, containers: containers, compact: issue.kind == .transient
                )
            }
            if containers.dockerIssue?.kind != .setup, containers.dockerIssue?.kind != .access {
                DockerTable(host: host, containers: containers)
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Show", selection: $containers.showStopped) {
                Text("Running").tag(false)
                Text("All").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            WorkloadSearchField(prompt: "Filter containers", text: $containers.dockerSearch)
            Spacer(minLength: 8)
            Text(countText)
                .font(Aero.font(.caption))
                .foregroundStyle(Aero.text.secondary)
                .monospacedDigit()
        }
    }

    private var countText: String {
        let shown = containers.filteredContainers.count
        let total = containers.containers.count
        return shown == total ? "\(total) containers" : "\(shown) of \(total) containers"
    }
}

/// The containers table: name, image, state, status, CPU, memory, ports and actions.
private struct DockerTable: View {
    let host: RemoteHost
    @Bindable var containers: HostContainersModel

    var body: some View {
        let rows = containers.filteredContainers
        AeroCard(padding: 0) {
            Table(rows, selection: $containers.selectedContainerID) {
                TableColumn("Name") { container in
                    HStack(spacing: 8) {
                        StatusOrb(tone: container.health.workloadTone, size: 10)
                        Text(container.name)
                            .font(Aero.font(.callout, weight: .semibold))
                            .lineLimit(1)
                    }
                    .help(container.id)
                }
                .width(min: 120, ideal: 170)
                TableColumn("Image") { container in
                    Text(container.image)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(container.image)
                }
                .width(min: 100, ideal: 170)
                TableColumn("State") { container in
                    AeroTag(container.state.rawValue.capitalized, tone: container.health.workloadTone)
                }
                .width(min: 80, ideal: 92, max: 120)
                TableColumn("Status") { container in
                    Text(container.status)
                        .lineLimit(1)
                        .foregroundStyle(Aero.text.secondary)
                        .help(container.status)
                }
                .width(min: 100, ideal: 160)
                TableColumn("CPU") { container in
                    Text(container.cpuText)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 50, ideal: 60, max: 80)
                TableColumn("Memory") { container in
                    Text(container.memoryText)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help(container.memoryHelp ?? "")
                }
                .width(min: 64, ideal: 80, max: 110)
                TableColumn("Ports") { container in
                    Text(container.portsText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(Aero.text.secondary)
                        .help(container.ports ?? "")
                }
                .width(min: 80, ideal: 150)
                TableColumn("") { container in
                    HStack(spacing: 10) {
                        RowActionButton(title: "Logs", systemImage: "doc.text.magnifyingglass") {
                            containers.showLogs(container)
                        }
                        RowActionButton(title: "Inspect", systemImage: "info.circle") {
                            containers.inspect(container)
                        }
                        RowActionButton(
                            title: "Open logs in terminal", systemImage: "terminal",
                            disabled: !containers.canOpenTerminal
                        ) {
                            containers.openLogsInTerminal(container)
                        }
                    }
                }
                .width(84)
            }
            .contextMenu(forSelectionType: ContainerInfo.ID.self) { ids in
                if let container = container(ids) {
                    Button("Logs", systemImage: "doc.text.magnifyingglass") { containers.showLogs(container) }
                    Button("Inspect", systemImage: "info.circle") { containers.inspect(container) }
                    Button("Open Logs in Terminal", systemImage: "terminal") { containers.openLogsInTerminal(container) }
                        .disabled(!containers.canOpenTerminal)
                    Divider()
                    Button("Copy Name", systemImage: "doc.on.doc") { copy(container.name) }
                    Button("Copy ID", systemImage: "number") { copy(container.id) }
                }
            } primaryAction: { ids in
                if let container = container(ids) { containers.showLogs(container) }
            }
            .font(Aero.font(.callout))
            .foregroundStyle(Aero.text.primary)
            .scrollContentBackground(.hidden)
            .alternatingRowBackgrounds(.disabled)
            .overlay {
                if rows.isEmpty, containers.dockerLoaded {
                    Text(containers.containers.isEmpty ? "No containers on this host." : "No containers match.")
                        .font(Aero.font(.callout))
                        .foregroundStyle(Aero.text.secondary)
                } else if !containers.dockerLoaded {
                    ProgressView().controlSize(.small)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Aero.radius.card, style: .continuous))
        }
    }

    private func container(_ ids: Set<ContainerInfo.ID>) -> ContainerInfo? {
        guard let id = ids.first else { return nil }
        return containers.containers.first { $0.id == id }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
