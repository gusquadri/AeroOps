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
/// Restarting chip, "100.0%", "123.4 MB" and the Logs and Inspect buttons and the Stop, Restart
/// or Delete menu. Sortable headers also fit their bold title beside the sort chevron, which takes
/// about 25 points.
private enum ContainerColumn: String, CaseIterable {
    case name, image, state, status, cpu, memory, ports, actions

    static let nameMinimum: CGFloat = 90
    /// A typical Compose container name (`aeroops-web-1`) with its orb.
    static let nameComfort: CGFloat = 110
    static let imageWidths = (min: CGFloat(80), ideal: CGFloat(140), max: CGFloat(320))
    static let statusWidths = (min: CGFloat(90), ideal: CGFloat(150), max: CGFloat(240))
    static let portsWidths = (min: CGFloat(70), ideal: CGFloat(110), max: CGFloat(280))
    static let stateWidth: CGFloat = 84
    static let cpuWidth: CGFloat = 52
    static let memoryWidth: CGFloat = 72
    static let actionsWidth: CGFloat = 66

    /// Ports give way first, then image, status, memory and CPU.
    static func layout(width: CGFloat) -> WorkloadTableLayout<ContainerColumn> {
        WorkloadTableLayout(
            width: width,
            columns: [
                .init(.name, width: nameMinimum),
                .init(.image, min: imageWidths.min, ideal: imageWidths.ideal),
                .init(.state, width: stateWidth),
                .init(.status, min: statusWidths.min, ideal: statusWidths.ideal),
                .init(.cpu, width: cpuWidth),
                .init(.memory, width: memoryWidth),
                .init(.ports, min: portsWidths.min, ideal: portsWidths.ideal),
                .init(.actions, width: actionsWidth),
            ],
            name: .name,
            nameComfort: nameComfort,
            dropOrder: [.ports, .image, .status, .memory, .cpu]
        )
    }
}

/// The containers table: name, image, state, status, CPU, memory, ports and actions. When the
/// table is too narrow for every column, optional ones give way
/// (``ContainerColumn/layout(width:)``) rather than the table scrolling sideways. Clicking a
/// header sorts by that column: text A to Z, CPU and memory highest first; clicking again flips it.
private struct DockerTable: View {
    let host: RemoteHost
    @Bindable var containers: HostContainersModel
    @State private var width: CGFloat = 0
    @State private var columns = TableColumnCustomization<ContainerInfo>()

    var body: some View {
        let rows = containers.filteredContainers
        let layout = ContainerColumn.layout(width: width)
        AeroCard(padding: 0) {
            // The table is created once its width is known, so it starts out filled.
            if width > 0 {
                table(rows, layout: layout)
            } else {
                Color.clear
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
            width = newWidth
            ContainerColumn.layout(width: newWidth).apply(to: &columns)
        }
    }

    private func table(_ rows: [ContainerInfo], layout: WorkloadTableLayout<ContainerColumn>) -> some View {
        Table(
            rows, selection: $containers.selectedContainerID, sortOrder: $containers.containerSortOrder,
            columnCustomization: $columns
        ) {
            TableColumn("Name", value: \.name) { container in
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
            .layoutColumn(ContainerColumn.name)
            TableColumn("Image", value: \.image) { container in
                Text(container.image)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(container.image)
            }
            .width(
                min: ContainerColumn.imageWidths.min, ideal: layout.width(.image),
                max: ContainerColumn.imageWidths.max
            )
            .layoutColumn(ContainerColumn.image)
            TableColumn("State", value: \.state.rawValue) { container in
                AeroTag(container.state.rawValue.capitalized, tone: container.health.workloadTone)
            }
            .width(ContainerColumn.stateWidth)
            .layoutColumn(ContainerColumn.state)
            TableColumn("Status", value: \.status) { container in
                Text(container.status)
                    .lineLimit(1)
                    .foregroundStyle(Aero.text.secondary)
                    .help(container.status)
            }
            .width(
                min: ContainerColumn.statusWidths.min, ideal: layout.width(.status),
                max: ContainerColumn.statusWidths.max
            )
            .layoutColumn(ContainerColumn.status)
            TableColumn("CPU", sortUsing: KeyPathComparator(\.cpuPercent, order: .reverse)) { container in
                Text(container.cpuText)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(ContainerColumn.cpuWidth)
            .layoutColumn(ContainerColumn.cpu)
            TableColumn("Memory", sortUsing: KeyPathComparator(\.memUsedBytes, order: .reverse)) { container in
                Text(container.memoryText)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(container.memoryHelp ?? "")
            }
            .width(ContainerColumn.memoryWidth)
            .layoutColumn(ContainerColumn.memory)
            TableColumn("Ports", value: \.portsText) { container in
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
            .layoutColumn(ContainerColumn.ports)
            TableColumn("") { container in
                HStack(spacing: 10) {
                    RowActionButton(title: "Logs", systemImage: "doc.text.magnifyingglass") {
                        containers.showLogs(container)
                    }
                    RowActionButton(title: "Inspect", systemImage: "info.circle") {
                        containers.inspect(container)
                    }
                    WorkloadActionsMenu(busy: containers.isBusy(container.id)) {
                        ContainerActionItems(container: container, containers: containers)
                    }
                }
            }
            .width(ContainerColumn.actionsWidth)
            .layoutColumn(ContainerColumn.actions)
        }
        .contextMenu(forSelectionType: ContainerInfo.ID.self) { ids in
            if let container = container(ids) {
                Button("Logs", systemImage: "doc.text.magnifyingglass") { containers.showLogs(container) }
                Button("Inspect", systemImage: "info.circle") { containers.inspect(container) }
                Button("Open Logs in Terminal", systemImage: "terminal") { containers.openLogsInTerminal(container) }
                    .disabled(!containers.canOpenTerminal)
                Divider()
                ContainerActionItems(container: container, containers: containers)
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
