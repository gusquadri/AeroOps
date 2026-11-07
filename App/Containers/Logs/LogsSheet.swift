import AeroCore
import AeroTheme
import SwiftUI

/// The Logs sheet for a container or pod: last 500 lines, follow, previous instance, container
/// picker, timestamps, search with highlights, copy, and Open in Terminal.
struct LogsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let viewer: LogViewerModel
    let containers: HostContainersModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            controls
            if let issue = viewer.issue {
                WorkloadIssueInline(issue: issue)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .aeroGlass(in: RoundedRectangle(cornerRadius: Aero.radius.inner, style: .continuous), shadow: nil)
            }
            if let notice = viewer.notice {
                noticeBar(notice)
            }
            LogTextView(controller: viewer.text)
                .clipShape(RoundedRectangle(cornerRadius: Aero.radius.inner, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Aero.radius.inner, style: .continuous)
                        .strokeBorder(Aero.glass.rimStrong.opacity(0.4), lineWidth: 1)
                }
                .overlay {
                    if viewer.status == .loading, viewer.lineCount == 0 {
                        ProgressView().controlSize(.small)
                    }
                }
            footer
        }
        .padding(16)
        .frame(minWidth: 760, idealWidth: 980, minHeight: 460, idealHeight: 660)
        .background { SkyBackground() }
        .onAppear { viewer.start() }
        .onDisappear { viewer.stop() }
        .task(id: viewer.searchText) {
            let query = viewer.searchText
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            viewer.search(query)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: viewer.isPod ? "helm" : "shippingbox")
                .font(Aero.font(.title3, weight: .semibold))
                .foregroundStyle(Aero.aquaDeep)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(viewer.title)
                    .font(Aero.font(.headline, weight: .semibold))
                    .foregroundStyle(Aero.text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(viewer.host.name)
                    .font(Aero.font(.caption))
                    .foregroundStyle(Aero.text.secondary)
            }
            statusTag
            Spacer(minLength: 8)
            Button("Open in Terminal", systemImage: "terminal") { containers.openLogsInTerminal(viewer) }
                .buttonStyle(.aquaSecondary)
                .disabled(!containers.canOpenTerminal || viewer.terminalCommand == nil)
                .help(viewer.terminalCommand.map { "Run in a terminal tab: \($0)" } ?? "")
            Button("Done") { dismiss() }
                .buttonStyle(.aqua)
                .keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder private var statusTag: some View {
        switch viewer.status {
        case .following: AeroTag("Following", systemImage: "dot.radiowaves.left.and.right", tint: Aero.leaf)
        case .loading: AeroTag("Loading", tone: .neutral)
        case .paused: AeroTag(viewer.previous ? "Previous instance" : "Snapshot", tone: viewer.previous ? .warning : .neutral)
        case .ended: AeroTag("Ended", tone: .neutral)
        case .failed: AeroTag("Failed", tone: .error)
        case .idle: EmptyView()
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Toggle("Follow", isOn: Binding(get: { viewer.follow }, set: { viewer.setFollow($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(viewer.previous)
                .help(viewer.previous ? "The previous instance has stopped; there is nothing to follow." : "Stream new lines as they are written")
            if viewer.isPod {
                if viewer.podContainers.count > 1 {
                    Picker("Container", selection: Binding(get: { viewer.container ?? "" }, set: { viewer.setContainer($0) })) {
                        ForEach(viewer.podContainers, id: \.name) { container in
                            Text(container.restartCount > 0 ? "\(container.name) (\(container.restartCount) restarts)" : container.name)
                                .tag(container.name)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                Toggle("Previous", isOn: Binding(get: { viewer.previous }, set: { viewer.setPrevious($0) }))
                    .toggleStyle(.checkbox)
                    .disabled(!viewer.canShowPrevious && !viewer.previous)
                    .help(viewer.canShowPrevious
                        ? "Show the logs of the instance before the last restart (kubectl logs --previous)"
                        : "Available after the container has restarted")
            }
            Toggle("Timestamps", isOn: Binding(get: { viewer.showTimestamps }, set: { viewer.showTimestamps = $0 }))
                .toggleStyle(.checkbox)
            Spacer(minLength: 8)
            searchField
            Menu {
                Button("Copy All") { viewer.copyAll() }
                Button("Copy Selection") { viewer.copySelection() }
                    .disabled(!viewer.hasSelection)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            } primaryAction: {
                if viewer.hasSelection { viewer.copySelection() } else { viewer.copyAll() }
            }
            .menuStyle(.button)
            .fixedSize()
            .help(viewer.hasSelection ? "Copy the selection" : "Copy all lines")
        }
        .font(Aero.font(.callout))
        .foregroundStyle(Aero.text.primary)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Aero.text.secondary)
                .accessibilityHidden(true)
            TextField("Search", text: Bindable(viewer).searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .frame(minWidth: 120, maxWidth: 200)
                .onSubmit { viewer.nextMatch() }
            if !viewer.searchText.isEmpty {
                Text(matchText)
                    .font(Aero.font(.caption))
                    .monospacedDigit()
                    .foregroundStyle(Aero.text.secondary)
                    .fixedSize()
                Button("Previous Match", systemImage: "chevron.up") { viewer.previousMatch() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(viewer.matchCount == 0)
                Button("Next Match", systemImage: "chevron.down") { viewer.nextMatch() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled(viewer.matchCount == 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .aeroGlass(in: Capsule(), shadow: Aero.shadow.control)
        .background {
            Button("Find") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
    }

    private var matchText: String {
        guard viewer.matchCount > 0 else { return "No matches" }
        let capped = viewer.matchCount >= LogTextController.maxMatches ? "\(viewer.matchCount)+" : "\(viewer.matchCount)"
        if let current = viewer.currentMatch { return "\(current + 1) of \(capped)" }
        return "\(capped) matches"
    }

    private func noticeBar(_ notice: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Aero.aquaDeep)
                .accessibilityHidden(true)
            Text(notice)
                .font(Aero.font(.caption))
                .foregroundStyle(Aero.text.primary)
            Spacer(minLength: 8)
            if viewer.previous {
                Button("Show Current Logs") { viewer.setPrevious(false) }
                    .buttonStyle(.aquaSecondary)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .aeroGlass(in: RoundedRectangle(cornerRadius: Aero.radius.inner, style: .continuous), shadow: nil)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(viewer.lineCount.formatted()) lines")
            if viewer.droppedLines > 0 {
                Text("\(viewer.droppedLines.formatted()) older lines dropped (keeps up to the last \(LogTextController.maxLines.formatted()))")
            }
            Spacer(minLength: 8)
            Text("Last \(LogViewerModel.tail) lines, ANSI colours removed")
        }
        .font(Aero.font(.caption))
        .monospacedDigit()
        .foregroundStyle(Aero.text.secondary)
    }
}

/// `docker inspect` for one container: a summary and the full JSON with a Copy button.
struct InspectSheet: View {
    @Environment(\.dismiss) private var dismiss
    let inspection: ContainerInspectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "info.circle")
                    .font(Aero.font(.title3, weight: .semibold))
                    .foregroundStyle(Aero.aquaDeep)
                    .accessibilityHidden(true)
                Text(inspection.name)
                    .font(Aero.font(.headline, weight: .semibold))
                    .foregroundStyle(Aero.text.primary)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button("Copy JSON", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(inspection.json, forType: .string)
                }
                .buttonStyle(.aquaSecondary)
                .disabled(inspection.json.isEmpty)
                Button("Done") { dismiss() }
                    .buttonStyle(.aqua)
                    .keyboardShortcut(.cancelAction)
            }
            if let summary = inspection.summary {
                summaryGrid(summary)
            }
            if let issue = inspection.issue {
                WorkloadIssueInline(issue: issue)
            }
            Text("The JSON includes the container's environment, which may contain secrets.")
                .font(Aero.font(.caption))
                .foregroundStyle(Aero.text.secondary)
            ScrollView([.vertical, .horizontal]) {
                Text(inspection.json)
                    .font(Aero.monospacedFont(.caption))
                    .foregroundStyle(Aero.text.primary)
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Aero.glass.solidFill, in: RoundedRectangle(cornerRadius: Aero.radius.inner, style: .continuous))
            .overlay {
                if inspection.isLoading { ProgressView().controlSize(.small) }
            }
        }
        .padding(16)
        .frame(minWidth: 640, idealWidth: 820, minHeight: 440, idealHeight: 620)
        .background { SkyBackground() }
        .onDisappear { inspection.cancel() }
    }

    private func summaryGrid(_ summary: DockerInspectSummary) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            row("Image", summary.image ?? MetricText.missing)
            row("ID", String(summary.id.prefix(12)))
            row("Restarts", "\(summary.restartCount)" + (summary.restartPolicy.map { " (policy \($0))" } ?? ""))
            if let health = summary.healthCheck { row("Health check", health.rawValue) }
            if let code = summary.exitCode { row("Exit code", "\(code)") }
            if let started = summary.startedAt { row("Started", started.formatted(date: .abbreviated, time: .standard)) }
            if let finished = summary.finishedAt { row("Finished", finished.formatted(date: .abbreviated, time: .standard)) }
            if !summary.ports.isEmpty { row("Ports", summary.ports.joined(separator: ", ")) }
        }
        .font(Aero.font(.callout))
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(Aero.text.secondary)
            Text(value)
                .foregroundStyle(Aero.text.primary)
                .textSelection(.enabled)
        }
    }
}
