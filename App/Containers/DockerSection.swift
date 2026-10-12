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

/// The containers table's columns. Fixed widths fit the content and the header: the
/// Restarting chip, "100.0%", "123.4 MB" and three row buttons.
private enum ContainerColumn: Hashable {
    case name, image, state, status, cpu, memory, ports, actions

    static let nameMinimum: CGFloat = 90
    /// A typical Compose container name (`aeroops-web-1`) with its orb, with room to spare.
    static let nameComfort: CGFloat = 130
    static let imageWidths = (min: CGFloat(80), ideal: CGFloat(140), max: CGFloat(320))
    static let statusWidths = (min: CGFloat(90), ideal: CGFloat(130), max: CGFloat(240))
    static let portsWidths = (min: CGFloat(70), ideal: CGFloat(110), max: CGFloat(280))

    /// Ports give way first, then image, status, memory and CPU.
    static func layout(width: CGFloat) -> WorkloadTableLayout<ContainerColumn> {
        WorkloadTableLayout(
            width: width,
            columns: [
                .init(.name, width: nameMinimum),
                .init(.image, min: imageWidths.min, ideal: imageWidths.ideal),
                .init(.state, width: 84),
                .init(.status, min: statusWidths.min, ideal: statusWidths.ideal),
                .init(.cpu, width: 50),
                .init(.memory, width: 62),
                .init(.ports, min: portsWidths.min, ideal: portsWidths.ideal),
                .init(.actions, width: 66),
            ],
            name: .name,
            nameComfort: nameComfort,
            dropOrder: [.ports, .image, .status, .memory, .cpu]
        )
    }
}

/// The containers table: name, image, state, status, CPU, memory, ports and actions. When the
/// table is too narrow for every column, optional ones give way
/// (``ContainerColumn/layout(width:)``) rather than the table scrolling sideways.
private struct DockerTable: View {
    let host: RemoteHost
    @Bindable var containers: HostContainersModel
    @State private var width: CGFloat = 0

    var body: some View {
        let rows = containers.filteredContainers
        let layout = ContainerColumn.layout(width: width)
        AeroCard(padding: 0) {
            ScrollViewReader { proxy in
                table(rows, layout: layout)
                    // A new table starts at the top; bring the selected container back into view.
                    .id(layout.identity)
                    .task(id: layout.identity) {
                        await Task.yield()
                        if let id = containers.selectedContainerID, rows.contains(where: { $0.id == id }) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func table(_ rows: [ContainerInfo], layout: WorkloadTableLayout<ContainerColumn>) -> some View {
        Table(rows, selection: $containers.selectedContainerID) {
            TableColumn("Name") { container in
                HStack(spacing: 8) {
                    StatusOrb(tone: container.health.workloadTone, size: 10)
                    Text(container.name)
                        .font(Aero.font(.callout, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(container.id)
            }
            .width(min: ContainerColumn.nameMinimum, ideal: layout.width(.name))
            if layout.shows(.image) {
                TableColumn("Image") { container in
                    Text(container.image)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(container.image)
                }
                .width(
                    min: ContainerColumn.imageWidths.min, ideal: layout.width(.image),
                    max: ContainerColumn.imageWidths.max
                )
            }
            TableColumn("State") { container in
                AeroTag(container.state.rawValue.capitalized, tone: container.health.workloadTone)
            }
            .width(layout.width(.state))
            if layout.shows(.status) {
                TableColumn("Status") { container in
                    Text(container.status)
                        .lineLimit(1)
                        .foregroundStyle(Aero.text.secondary)
                        .help(container.status)
                }
                .width(
                    min: ContainerColumn.statusWidths.min, ideal: layout.width(.status),
                    max: ContainerColumn.statusWidths.max
                )
            }
            if layout.shows(.cpu) {
                TableColumn("CPU") { container in
                    Text(container.cpuText)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(layout.width(.cpu))
            }
            if layout.shows(.memory) {
                TableColumn("Memory") { container in
                    Text(container.memoryText)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help(container.memoryHelp ?? "")
                }
                .width(layout.width(.memory))
            }
            if layout.shows(.ports) {
                TableColumn("Ports") { container in
                    Text(container.portsText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(Aero.text.secondary)
                        .help(container.ports ?? "")
                }
                .width(
                    min: ContainerColumn.portsWidths.min, ideal: layout.width(.ports),
                    max: ContainerColumn.portsWidths.max
                )
            }
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
            .width(layout.width(.actions))
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

    private func container(_ ids: Set<ContainerInfo.ID>) -> ContainerInfo? {
        guard let id = ids.first else { return nil }
        return containers.containers.first { $0.id == id }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
