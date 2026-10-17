import AeroCore
import AeroTheme
import Collectors
import SwiftUI

/// Containers tab: the selected host's Docker containers and Kubernetes pods, refreshed every
/// 5 s while the tab and the window are visible.
struct ContainersView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.hosts.isEmpty {
            AeroEmptyState(
                systemImage: "shippingbox",
                title: "Containers and pods",
                message: "Add a host to see its Docker containers and Kubernetes pods here, with status, restarts and age, and logs one click away."
            ) {
                AddHostButton()
            }
        } else if let host = model.selectedHost {
            HostContainersView(host: host, containers: model.containers(for: host.id))
                .id(host.id)
        } else {
            AeroEmptyState(
                systemImage: "sidebar.left",
                title: "Pick a host",
                message: "Choose a host in the sidebar to see its Docker containers and Kubernetes pods."
            )
        }
    }
}

/// One host's containers and pods.
struct HostContainersView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sidebarVisibility) private var sidebarVisibility
    let host: RemoteHost
    @Bindable var containers: HostContainersModel
    @State private var windowVisible = true
    @State private var width: CGFloat = 0
    /// Whether opening the inspector hid the sidebar, so closing it shows the sidebar again.
    @State private var hidSidebar = false

    /// The inspector's ideal width.
    static let inspectorWidth: CGFloat = 340
    /// The width the header, the pods toolbar and a pods table with names, status and row
    /// buttons need beside the inspector.
    static let widthBesideInspector: CGFloat = 600

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ContainersHeader(host: host, containers: containers)
            content
        }
        .padding(16)
        // Zero minimums decouple the split view's column minimum from this content. Without them,
        // wrapped text and toolbars feed a content-dependent minimum size back into
        // NSSplitView, which can loop until AppKit throws "more Update Constraints in Window
        // passes than there are views in the window". (A constant minimum while the inspector
        // is open throws too, which is why a narrow window hides the sidebar instead.)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .clipped()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
            let appeared = width == 0
            width = newWidth
            if appeared, containers.inspectorPresented {
                // Back on the tab with the inspector still open.
                hideSidebar(ifNarrowerThan: Self.widthBesideInspector)
            } else if hidSidebar, !containers.inspectorPresented {
                // The inspector has closed and handed its width back.
                showSidebarAgain()
            }
        }
        .onChange(of: containers.inspectorPresented) { _, presented in
            if presented { hideSidebar(ifNarrowerThan: Self.inspectorWidth + Self.widthBesideInspector) }
        }
        .onChange(of: sidebarVisibility.wrappedValue) { _, visibility in
            // Shown by hand: it stays.
            if visibility != .detailOnly { hidSidebar = false }
        }
        .onDisappear(perform: showSidebarAgain)
        .background { WindowVisibilityReader(isVisible: $windowVisible) }
        .task(id: windowVisible) {
            guard windowVisible else { return }
            await containers.poll()
        }
        .sheet(item: $containers.logs) { viewer in
            LogsSheet(viewer: viewer, containers: containers)
        }
        .sheet(item: $containers.inspection) { inspection in
            InspectSheet(inspection: inspection)
        }
        .confirmationDialog(
            containers.confirmation?.confirmationTitle ?? "",
            isPresented: isPresent($containers.confirmation),
            presenting: containers.confirmation
        ) { request in
            Button(request.confirmButtonTitle, role: .destructive) { containers.perform(request) }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(request.confirmationMessage)
        }
        .alert(
            containers.actionFailure?.title ?? "",
            isPresented: isPresent($containers.actionFailure),
            presenting: containers.actionFailure
        ) { _ in
            Button("OK") {}
        } message: { failure in
            Text(failure.message)
        }
        .inspector(isPresented: $containers.inspectorPresented) {
            PodInspectorView(containers: containers)
                .inspectorColumnWidth(min: 300, ideal: Self.inspectorWidth, max: 560)
        }
    }

    /// Opening the inspector in a window too narrow for it and the content hides the sidebar,
    /// until the inspector closes or the tab changes.
    private func hideSidebar(ifNarrowerThan needed: CGFloat) {
        guard width > 0, width < needed, sidebarVisibility.wrappedValue != .detailOnly else { return }
        hidSidebar = true
        sidebarVisibility.wrappedValue = .detailOnly
    }

    /// Shows the sidebar again once the inspector has closed. Through the sidebar toggle
    /// action, like the toolbar button: setting the split view's visibility to `.all` grows the
    /// window by the sidebar's width instead.
    private func showSidebarAgain() {
        guard hidSidebar else { return }
        hidSidebar = false
        guard sidebarVisibility.wrappedValue == .detailOnly else { return }
        NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
    }

    @ViewBuilder private var content: some View {
        if let issue = containers.connectionIssue, containers.capabilities == nil || issue.kind == .access {
            WorkloadIssueCard(issue: issue, hostID: host.id, containers: containers)
            Spacer(minLength: 0)
        } else if containers.capabilities == nil {
            LoadingCard(text: "Looking for Docker and Kubernetes on \(host.name)…")
            Spacer(minLength: 0)
        } else if containers.availableSections.isEmpty {
            NothingFoundCard(host: host, containers: containers)
            Spacer(minLength: 0)
        } else {
            if let issue = containers.connectionIssue {
                WorkloadIssueCard(issue: issue, hostID: host.id, containers: containers, compact: true)
            }
            switch containers.visibleSection {
            case .docker?:
                DockerSection(host: host, containers: containers)
            case .kubernetes?:
                PodsSection(host: host, containers: containers)
            case nil:
                EmptyView()
            }
        }
    }
}

// MARK: - Header

/// Host name, what the probe found, last update, the section switcher and Refresh.
private struct ContainersHeader: View {
    @Environment(AppModel.self) private var model
    let host: RemoteHost
    @Bindable var containers: HostContainersModel

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            let state = model.displayState(for: host.id)
            let blocked = model.hostKeyBlock(for: host.id) != nil
            StatusBubble(tone: state.orbTone(blocked: blocked), logo: state.systemLogo, size: 44)
                .help(state.title(blocked: blocked))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                hostMenu
                HStack(spacing: 6) {
                    ForEach(capabilityTags, id: \.text) { tag in
                        // The tags keep their text; the updated label gives way first.
                        AeroTag(tag.text, systemImage: tag.symbol, tint: tag.tint)
                            .fixedSize()
                    }
                    updatedLabel
                }
                .lineLimit(1)
            }
            Spacer(minLength: 12)
            if containers.availableSections.count > 1 {
                Picker("Section", selection: sectionBinding) {
                    ForEach(containers.availableSections) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Button {
                Task { await containers.refresh(reprobe: true) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.aquaSecondary)
            .disabled(containers.isRefreshing)
            .help("Probe the host again and reload containers and pods")
            .keyboardShortcut("r", modifiers: .command)
        }
    }

    /// The host's name as a pull-down of every host, each with its status bubble. Picking one
    /// selects it, as the sidebar does. A list taller than the screen scrolls, as menus do.
    private var hostMenu: some View {
        Menu {
            Picker("Host", selection: hostSelection) {
                ForEach(model.hosts) { other in
                    let state = model.displayState(for: other.id)
                    Label {
                        Text(other.name)
                    } icon: {
                        Image(nsImage: StatusBubbleImage.image(
                            tone: state.orbTone(blocked: model.hostKeyBlock(for: other.id) != nil),
                            logo: state.systemLogo
                        ))
                    }
                    .tag(other.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(host.name)
                    .font(Aero.font(.title2, weight: .semibold))
                    .foregroundStyle(Aero.text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(Aero.font(.callout, weight: .semibold))
                    .foregroundStyle(Aero.text.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Switch to another host")
        .accessibilityLabel("Host")
        .accessibilityValue(host.name)
    }

    private var hostSelection: Binding<RemoteHost.ID> {
        Binding(
            get: { host.id },
            set: { model.selection = $0 }
        )
    }

    private var sectionBinding: Binding<HostContainersModel.Section> {
        Binding(
            get: { containers.visibleSection ?? .docker },
            set: { containers.section = $0 }
        )
    }

    @ViewBuilder private var updatedLabel: some View {
        if containers.isRefreshing {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Updating…")
            }
            .font(Aero.font(.caption))
            .foregroundStyle(Aero.text.secondary)
        } else if containers.isPollingHalted {
            Text("Paused until Refresh")
                .font(Aero.font(.caption))
                .foregroundStyle(Aero.text.secondary)
        } else if let date = containers.lastRefresh {
            Text("Updated \(date, style: .relative) ago")
                .font(Aero.font(.caption))
                .foregroundStyle(Aero.text.secondary)
        }
    }

    private struct CapabilityTag {
        var text: String
        var symbol: String
        var tint: Color
    }

    private var capabilityTags: [CapabilityTag] {
        guard let caps = containers.capabilities else { return [] }
        var tags: [CapabilityTag] = []
        if caps.contains(.docker) {
            tags.append(CapabilityTag(
                text: "Docker", symbol: "shippingbox",
                tint: containers.dockerIssue == nil ? Aero.leaf : Aero.sun
            ))
        }
        if caps.contains(.podman) {
            tags.append(CapabilityTag(text: "Podman", symbol: "shippingbox", tint: Aero.neutral))
        }
        if containers.showsKubernetes {
            let name = caps.contains(.k3s) ? "k3s" : "Kubernetes"
            tags.append(CapabilityTag(
                text: name, symbol: "helm",
                tint: containers.podsIssue == nil ? Aero.leaf : Aero.sun
            ))
        }
        return tags
    }
}

/// Small status bubbles as images, for menu items, which show an image but not a view. Each tone
/// and logo is rendered once.
@MainActor
private enum StatusBubbleImage {
    private struct Key: Hashable {
        var tone: OrbTone
        var logo: SystemLogo?
    }

    /// The bubble's diameter, a menu item's icon size.
    private static let size: CGFloat = 16
    private static var cache: [Key: NSImage] = [:]

    static func image(tone: OrbTone, logo: SystemLogo?) -> NSImage {
        let key = Key(tone: tone, logo: logo)
        if let image = cache[key] { return image }
        // A point of room for the bubble's shadow.
        let side = size + 2
        let renderer = ImageRenderer(content: StatusBubble(tone: tone, logo: logo, size: size).padding(1))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.cgImage.map { NSImage(cgImage: $0, size: NSSize(width: side, height: side)) } ?? NSImage()
        cache[key] = image
        return image
    }
}

// MARK: - Hints

/// A collector, ssh or input problem with its hint and a way to fix it.
struct WorkloadIssueCard: View {
    @Environment(AppModel.self) private var model
    let issue: WorkloadIssue
    let hostID: RemoteHost.ID
    var containers: HostContainersModel?
    var compact = false
    @State private var applyError: String?

    var body: some View {
        AeroCard(padding: compact ? 12 : 18) {
            HStack(alignment: .top, spacing: 12) {
                StatusOrb(tone: issue.kind == .transient ? .warning : .error, size: compact ? 12 : 16)
                    .padding(.top, compact ? 3 : 4)
                VStack(alignment: .leading, spacing: 6) {
                    // No vertical fixedSize here (or in any text outside a scroll view): it makes
                    // the minimum height of the whole detail column the height of this text
                    // wrapped at zero width, which the split view cannot satisfy and loops on.
                    Text(issue.title)
                        .font(Aero.font(compact ? .callout : .headline, weight: .semibold))
                        .foregroundStyle(Aero.text.primary)
                        .textSelection(.enabled)
                    if let hint = issue.hint {
                        Text(hint)
                            .font(Aero.font(compact ? .caption : .callout))
                            .foregroundStyle(Aero.text.secondary)
                            .textSelection(.enabled)
                    }
                    if let applyError {
                        ValidationMessage(text: applyError)
                    }
                    if !compact, issue.offersHostEditor || issue.suggestedPrefix != nil {
                        HStack(spacing: 8) {
                            if let prefix = issue.suggestedPrefix {
                                Button("Use “\(prefix)”", systemImage: "wand.and.stars") { apply(prefix) }
                                    .buttonStyle(.aqua)
                                    .help("Set this host's kubectl prefix to “\(prefix)” and try again")
                            }
                            if issue.offersHostEditor {
                                Button("Edit Host…", systemImage: "slider.horizontal.3") { model.requestEdit(hostID) }
                                    .buttonStyle(issue.suggestedPrefix == nil ? .aqua : .aquaSecondary)
                            }
                            if let containers {
                                Button("Refresh", systemImage: "arrow.clockwise") {
                                    Task { await containers.refresh(reprobe: true) }
                                }
                                .buttonStyle(.aquaSecondary)
                                .disabled(containers.isRefreshing)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func apply(_ prefix: String) {
        guard var host = model.host(id: hostID) else { return }
        host.kubectlPrefix = prefix
        do {
            try model.updateHost(host)
            applyError = nil
        } catch {
            applyError = error.localizedDescription
        }
    }
}

/// Shown while the first probe runs.
private struct LoadingCard: View {
    let text: String

    var body: some View {
        AeroCard(padding: 18) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(text)
                    .font(Aero.font(.callout))
                    .foregroundStyle(Aero.text.secondary)
                Spacer(minLength: 0)
            }
        }
    }
}

/// The probe found neither Docker nor Kubernetes.
private struct NothingFoundCard: View {
    @Environment(AppModel.self) private var model
    let host: RemoteHost
    let containers: HostContainersModel

    var body: some View {
        AeroCard(padding: 18) {
            HStack(alignment: .top, spacing: 12) {
                StatusOrb(tone: .neutral, size: 16)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 6) {
                    Text("No Docker or Kubernetes on \(host.name)")
                        .font(Aero.font(.headline, weight: .semibold))
                        .foregroundStyle(Aero.text.primary)
                    Text("AeroOps looked for docker, podman, kubectl and k3s on \(host.user)'s PATH. If kubectl lives elsewhere, set a kubectl prefix in the host editor.")
                        .font(Aero.font(.callout))
                        .foregroundStyle(Aero.text.secondary)
                    HStack(spacing: 8) {
                        Button("Edit Host…", systemImage: "slider.horizontal.3") { model.requestEdit(host.id) }
                            .buttonStyle(.aqua)
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            Task { await containers.refresh(reprobe: true) }
                        }
                        .buttonStyle(.aquaSecondary)
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Shared bits

/// A search field for the section toolbars.
struct WorkloadSearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Aero.text.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(Aero.font(.callout))
                .foregroundStyle(Aero.text.primary)
                .frame(minWidth: 60, idealWidth: 160)
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(Aero.text.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .aeroGlass(in: Capsule(), shadow: Aero.shadow.control)
        .frame(maxWidth: 260)
    }
}

/// A row action: an icon button with a tooltip.
struct RowActionButton: View {
    let title: String
    let systemImage: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(Aero.aquaDeep)
            .help(title)
            .disabled(disabled)
    }
}

/// Reports whether the window is on screen (not minimised, hidden or fully covered), so
/// polling can pause.
struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onChange = { visible in
            if isVisible != visible { isVisible = visible }
        }
        return view
    }

    func updateNSView(_ nsView: VisibilityView, context: Context) {
        nsView.onChange = { visible in
            if isVisible != visible { isVisible = visible }
        }
    }

    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        // Set and cleared on the main actor; deinit is the last reference, so nothing races.
        nonisolated(unsafe) private var observer: (any NSObjectProtocol)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        private func report() {
            guard let window else { return }
            onChange?(window.occlusionState.contains(.visible))
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

extension ContainerInfo {
    /// `12.3 MB` (and the limit in the tooltip), or an em dash.
    var memoryText: String {
        guard let used = memUsedBytes else { return MetricText.missing }
        return used.formatted(.byteCount(style: .memory))
    }

    var memoryHelp: String? {
        guard let used = memUsedBytes, let limit = memLimitBytes, limit > 0 else { return nil }
        let percent = (Double(used) / Double(limit)).formatted(.percent.precision(.fractionLength(1)))
        return "\(used.formatted(.byteCount(style: .memory))) of \(limit.formatted(.byteCount(style: .memory))) (\(percent))"
    }

    var cpuText: String {
        guard let cpuPercent else { return MetricText.missing }
        return (cpuPercent / 100).formatted(.percent.precision(.fractionLength(1)))
    }

    /// `docker ps` ports without the IPv6 duplicates: `0.0.0.0:8080->80/tcp`.
    var portsText: String {
        guard let ports, !ports.isEmpty else { return "" }
        let parts = ports.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let ipv4 = parts.filter { !$0.hasPrefix("[::]") && !$0.hasPrefix(":::") }
        return (ipv4.isEmpty ? parts : ipv4).joined(separator: ", ")
    }
}

extension PodInfo {
    /// `true` when the metrics API reported this pod.
    var hasUsage: Bool { cpuMillicores != nil || memUsedBytes != nil }

    /// The Ready column's sort key: the share of containers ready, so `1/3` sorts before `1/1`.
    var readyFraction: Double {
        containerCount == 0 ? 0 : Double(readyCount) / Double(containerCount)
    }

    /// The Age column's sort key: larger for older pods; `nil` when the creation time is unknown.
    var ageSortKey: TimeInterval? {
        createdAt.map { -$0.timeIntervalSinceReferenceDate }
    }

    /// CPU as `docker stats` shows it, where 100% is one core (`250m` is `25.0%`), or an em dash.
    var cpuText: String {
        guard let cpuMillicores else { return MetricText.missing }
        return Self.corePercent(cpuMillicores)
    }

    /// `25.0% of one core, 50.0% of its 0.5-core limit`, or that there is no limit.
    var cpuHelp: String? {
        guard let cpuMillicores else { return nil }
        let used = "\(Self.corePercent(cpuMillicores)) of one core"
        guard let limit = cpuLimitMillicores, limit > 0 else { return "\(used), no CPU limit" }
        let share = (Double(cpuMillicores) / Double(limit)).formatted(.percent.precision(.fractionLength(1)))
        let cores = (Double(limit) / 1000).formatted(.number.precision(.fractionLength(0...3)))
        return "\(used), \(share) of its \(cores)-core limit"
    }

    /// Millicores as a share of one core: `250` is `25.0%`.
    private static func corePercent(_ millicores: Int) -> String {
        (Double(millicores) / 1000).formatted(.percent.precision(.fractionLength(1)))
    }

    /// `12.3 MB` (working set), or an em dash.
    var memoryText: String {
        MetricText.bytes(memUsedBytes)
    }

    /// `12.3 MB of 64 MB limit (19.2%)`, or that there is no limit.
    var memoryHelp: String? {
        guard let used = memUsedBytes else { return nil }
        let usedText = used.formatted(.byteCount(style: .memory))
        guard let limit = memLimitBytes, limit > 0 else { return "\(usedText), no memory limit" }
        let percent = (Double(used) / Double(limit)).formatted(.percent.precision(.fractionLength(1)))
        return "\(usedText) of \(limit.formatted(.byteCount(style: .memory))) limit (\(percent))"
    }
}

#Preview("Containers · host selected") {
    let model = AppModel.preview()
    model.selection = SampleData.hosts[2].id
    return ContainersView()
        .environment(model)
        .background { SkyBackground() }
        .frame(width: 900, height: 600)
}

#Preview("Containers · no hosts") {
    ContainersView()
        .environment(AppModel.preview(hosts: []))
        .background { SkyBackground() }
        .frame(width: 800, height: 600)
}
