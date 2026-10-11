import AeroCore
import AeroTheme
import SwiftUI

/// Kubernetes pods: namespace picker, search, and the table with per-row actions.
struct PodsSection: View {
    let host: RemoteHost
    @Bindable var containers: HostContainersModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            if let issue = containers.podsIssue {
                WorkloadIssueCard(
                    issue: issue, hostID: host.id, containers: containers, compact: issue.kind == .transient
                )
            }
            if containers.podsIssue?.kind != .setup, containers.podsIssue?.kind != .access {
                PodTable(containers: containers)
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Namespace", selection: $containers.namespace) {
                Text("All namespaces").tag(String?.none)
                Divider()
                ForEach(namespaceChoices, id: \.self) { namespace in
                    Text(namespace).tag(String?.some(namespace))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("Namespace")
            WorkloadSearchField(prompt: "Filter pods", text: $containers.podSearch)
            Spacer(minLength: 8)
            // The tag, count and button keep their size; the search field gives way when the
            // inspector narrows the column.
            if crashLooping > 0 {
                AeroTag("\(crashLooping) crash-looping", tone: .error)
                    .fixedSize()
            }
            Text(countText)
                .font(Aero.font(.caption))
                .foregroundStyle(Aero.text.secondary)
                .monospacedDigit()
                .fixedSize()
            Button {
                containers.inspectorPresented.toggle()
            } label: {
                Label("Details", systemImage: "sidebar.trailing")
            }
            .buttonStyle(.aquaSecondary)
            .fixedSize()
            .help("Show the selected pod's events and describe output")
        }
    }

    /// Discovered namespaces, plus the chosen one if it has no pods right now.
    private var namespaceChoices: [String] {
        var names = containers.namespaces
        if let chosen = containers.namespace, !names.contains(chosen) { names.append(chosen) }
        return names
    }

    private var crashLooping: Int {
        containers.filteredPods.count(where: \.isCrashLooping)
    }

    private var countText: String {
        let shown = containers.filteredPods.count
        let total = containers.pods.count
        return shown == total ? "\(total) pods" : "\(shown) of \(total) pods"
    }
}

/// The pods table: namespace, name, ready, status, restarts, age, node and actions.
private struct PodTable: View {
    @Bindable var containers: HostContainersModel

    var body: some View {
        let rows = containers.filteredPods
        AeroCard(padding: 0) {
            Table(rows, selection: $containers.selectedPodID) {
                TableColumn("Namespace") { pod in
                    Text(pod.namespace)
                        .lineLimit(1)
                        .foregroundStyle(Aero.text.secondary)
                }
                .width(min: 64, ideal: 84)
                TableColumn("Name") { pod in
                    HStack(spacing: 8) {
                        StatusOrb(tone: pod.health.workloadTone, size: 10)
                        Text(pod.name)
                            .font(Aero.font(.callout, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .help(pod.id)
                }
                .width(min: 120, ideal: 190)
                TableColumn("Ready") { pod in
                    Text("\(pod.readyCount)/\(pod.containerCount)")
                        .monospacedDigit()
                }
                .width(min: 40, ideal: 44, max: 60)
                TableColumn("Status") { pod in
                    AeroTag(pod.displayStatus, tone: pod.health.workloadTone)
                        .help(statusHelp(pod))
                }
                .width(min: 90, ideal: 120)
                TableColumn("Restarts") { pod in
                    restarts(pod)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 56, ideal: 60, max: 90)
                TableColumn("Age") { pod in
                    Text(pod.age() ?? MetricText.missing)
                        .monospacedDigit()
                        .foregroundStyle(Aero.text.secondary)
                }
                .width(min: 36, ideal: 40, max: 60)
                TableColumn("Node") { pod in
                    Text(pod.nodeName ?? MetricText.missing)
                        .lineLimit(1)
                        .foregroundStyle(Aero.text.secondary)
                }
                .width(min: 60, ideal: 90)
                TableColumn("") { pod in
                    HStack(spacing: 10) {
                        RowActionButton(title: "Logs", systemImage: "doc.text.magnifyingglass") {
                            containers.showLogs(pod)
                        }
                        RowActionButton(
                            title: "Previous logs (the crashed instance)",
                            systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                            disabled: pod.restarts == 0
                        ) {
                            containers.showPreviousLogs(pod)
                        }
                        RowActionButton(title: "Events and describe", systemImage: "sidebar.trailing") {
                            containers.showDetail(pod)
                        }
                    }
                }
                .width(84)
            }
            .contextMenu(forSelectionType: PodInfo.ID.self) { ids in
                if let pod = pod(ids) {
                    Button("Logs", systemImage: "doc.text.magnifyingglass") { containers.showLogs(pod) }
                    if pod.containers.count > 1 {
                        Menu("Logs of Container") {
                            ForEach(pod.containers, id: \.name) { container in
                                Button(container.name) { containers.showLogs(pod, container: container.name) }
                            }
                        }
                    }
                    Button("Previous Logs", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") {
                        containers.showPreviousLogs(pod)
                    }
                    .disabled(pod.restarts == 0)
                    Button("Events and Describe", systemImage: "sidebar.trailing") { containers.showDetail(pod) }
                    Button("Open Logs in Terminal", systemImage: "terminal") { containers.openLogsInTerminal(pod) }
                        .disabled(!containers.canOpenTerminal)
                    Divider()
                    Button("Copy Name", systemImage: "doc.on.doc") { copy(pod.name) }
                }
            } primaryAction: { ids in
                if let pod = pod(ids) { containers.showLogs(pod) }
            }
            .font(Aero.font(.callout))
            .foregroundStyle(Aero.text.primary)
            .scrollContentBackground(.hidden)
            .alternatingRowBackgrounds(.disabled)
            .overlay {
                if rows.isEmpty, containers.podsLoaded {
                    Text(containers.pods.isEmpty ? "No pods on this cluster." : "No pods match.")
                        .font(Aero.font(.callout))
                        .foregroundStyle(Aero.text.secondary)
                } else if !containers.podsLoaded {
                    ProgressView().controlSize(.small)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Aero.radius.card, style: .continuous))
        }
    }

    /// Restart count; red with the count for crash-looping pods.
    @ViewBuilder private func restarts(_ pod: PodInfo) -> some View {
        if pod.isCrashLooping {
            AeroTag("\(pod.restarts)", systemImage: "arrow.triangle.2.circlepath", tint: Aero.coral)
                .help("Crash-looping: restarted \(pod.restarts) times")
        } else {
            Text("\(pod.restarts)")
                .monospacedDigit()
                .foregroundStyle(pod.restarts > 0 ? Aero.text.primary : Aero.text.secondary)
        }
    }

    private func statusHelp(_ pod: PodInfo) -> String {
        pod.containers.map { container in
            var parts = [container.name, container.ready ? "ready" : "not ready"]
            if let reason = container.waitingReason { parts.append(reason) }
            if let reason = container.terminatedReason { parts.append(reason) }
            if let code = container.exitCode { parts.append("exit \(code)") }
            if container.restartCount > 0 { parts.append("\(container.restartCount) restarts") }
            return parts.joined(separator: " · ")
        }
        .joined(separator: "\n")
    }

    private func pod(_ ids: Set<PodInfo.ID>) -> PodInfo? {
        guard let id = ids.first else { return nil }
        return containers.pods.first { $0.id == id }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Inspector

/// Events and `kubectl describe` for the selected pod.
struct PodInspectorView: View {
    @Bindable var containers: HostContainersModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let detail = containers.podDetail {
                header(detail)
                Picker("View", selection: $containers.inspectorTab) {
                    ForEach(HostContainersModel.InspectorTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch containers.inspectorTab {
                case .events: PodEventsList(detail: detail)
                case .describe: PodDescribeView(detail: detail)
                }
            } else {
                Spacer()
                Text("Select a pod to see its events and describe output.")
                    .font(Aero.font(.callout))
                    .foregroundStyle(Aero.text.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(14)
        // Zero minimums: the inspector column's minimum must not follow its content (see
        // HostContainersView).
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background { SkyBackground() }
    }

    private func header(_ detail: PodDetailModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let pod = containers.selectedPod {
                    StatusOrb(tone: pod.health.workloadTone)
                }
                Text(detail.name)
                    .font(Aero.font(.headline, weight: .semibold))
                    .foregroundStyle(Aero.text.primary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                Button("Reload", systemImage: "arrow.clockwise") { containers.reloadPodDetail() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Aero.aquaDeep)
                    .disabled(detail.isLoading)
                    .help("Load events and describe again")
            }
            HStack(spacing: 6) {
                AeroTag(detail.namespace, systemImage: "folder")
                if let pod = containers.selectedPod {
                    AeroTag(pod.displayStatus, tone: pod.health.workloadTone)
                }
                if detail.isGone {
                    AeroTag("Gone", tone: .neutral)
                }
            }
            // On its own row so the inspector's minimum width stays within its column minimum.
            if let pod = containers.selectedPod, pod.restarts > 0 {
                Button("Previous Logs", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") {
                    containers.showPreviousLogs(pod)
                }
                .buttonStyle(.aquaSecondary)
                .controlSize(.small)
                .help("Logs of the instance before the last restart")
            }
        }
    }
}

private struct PodEventsList: View {
    let detail: PodDetailModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if let issue = detail.eventsIssue {
                    WorkloadIssueInline(issue: issue)
                }
                if detail.events.isEmpty, detail.eventsIssue == nil {
                    Text(detail.isLoading ? "Loading events…" : "No events for this pod (Kubernetes keeps them for about an hour).")
                        .font(Aero.font(.callout))
                        .foregroundStyle(Aero.text.secondary)
                        .padding(.top, 4)
                }
                ForEach(detail.sortedEvents) { event in
                    PodEventRow(event: event)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
    }
}

private struct PodEventRow: View {
    let event: PodEvent

    var body: some View {
        AeroCard(padding: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    StatusOrb(tone: event.isWarning ? .error : .healthy, size: 9)
                    Text(event.reason)
                        .font(Aero.font(.callout, weight: .semibold))
                        .foregroundStyle(Aero.text.primary)
                    Spacer(minLength: 4)
                    if event.count > 1 {
                        Text("×\(event.count)")
                            .font(Aero.font(.caption))
                            .monospacedDigit()
                            .foregroundStyle(Aero.text.secondary)
                    }
                    if let age = event.age() {
                        Text(age)
                            .font(Aero.font(.caption))
                            .monospacedDigit()
                            .foregroundStyle(Aero.text.secondary)
                    }
                }
                Text(event.message)
                    .font(Aero.font(.caption))
                    .foregroundStyle(Aero.text.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let source = event.source {
                    Text(source)
                        .font(Aero.font(.caption2))
                        .foregroundStyle(Aero.text.secondary)
                }
            }
        }
    }
}

private struct PodDescribeView: View {
    let detail: PodDetailModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let issue = detail.describeIssue {
                WorkloadIssueInline(issue: issue)
            }
            ScrollView([.vertical, .horizontal]) {
                Text(detail.describe.isEmpty ? (detail.isLoading ? "Loading…" : "") : detail.describe)
                    .font(Aero.font(.caption).monospaced())
                    .foregroundStyle(Aero.text.primary)
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Aero.glass.solidFill, in: RoundedRectangle(cornerRadius: Aero.radius.inner, style: .continuous))
            if detail.describeTruncated {
                Text("Output was cut at the size limit.")
                    .font(Aero.font(.caption2))
                    .foregroundStyle(Aero.text.secondary)
            }
        }
    }
}

/// A one-line issue (title and hint) for small spaces.
struct WorkloadIssueInline: View {
    let issue: WorkloadIssue

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusOrb(tone: issue.kind == .transient ? .warning : .error, size: 10)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title)
                    .font(Aero.font(.callout, weight: .semibold))
                    .foregroundStyle(Aero.text.primary)
                if let hint = issue.hint {
                    Text(hint)
                        .font(Aero.font(.caption))
                        .foregroundStyle(Aero.text.secondary)
                }
            }
            .textSelection(.enabled)
        }
    }
}
