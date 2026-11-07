import AeroCore
import AeroTheme
import Collectors
import SwiftUI

/// The Containers tab: every server matching the search field, then its Docker containers and Kubernetes pods. Holds the
/// stack and the prompts of its screens, and ends logs and inspections when their screens close.
struct ContainersScreen: View {
    @Environment(MobileModel.self) private var model
    @Environment(MobileNavigator.self) private var navigator
    @State private var search = ""

    var body: some View {
        @Bindable var navigator = navigator
        NavigationStack(path: $navigator.containerPath) {
            content
                .background { SkyBackground() }
                .searchable(text: $search, prompt: "Name or address")
                .navigationTitle("Containers")
                .navigationDestination(for: ContainersRoute.self, destination: destination)
        }
        .modifier(WorkloadPrompts(containers: navigator.containerPath.first.map { model.containers(for: $0.hostID) }))
        .onChange(of: navigator.containerPath, release)
    }

    @ViewBuilder
    private var content: some View {
        if model.hosts.isEmpty {
            NoServersView()
        } else {
            let hosts = model.hosts.matching(search: search)
            List(hosts) { host in
                NavigationLink(value: ContainersRoute.host(host.id)) {
                    HostRow(
                        host: host,
                        status: model.displayState(for: host.id).status,
                        detail: model.containers(for: host.id).countSummary
                    )
                }
                .listRowBackground(Aero.glass.fill)
            }
            .scrollContentBackground(.hidden)
            .overlay { if hosts.isEmpty { NoMatchingHostsView(search: search).padding(16) } }
        }
    }

    @ViewBuilder
    private func destination(_ route: ContainersRoute) -> some View {
        let containers = model.containers(for: route.hostID)
        switch route {
        case .host: HostWorkloadsScreen(containers: containers)
        case .container(_, let id): ContainerDetailScreen(containers: containers, id: id)
        case .pod(_, let id): PodDetailScreen(containers: containers, id: id)
        case .inspection, .describe: rawOutput(route, containers)
        case .logs: LogsScreen(containers: containers)
        }
    }

    @ViewBuilder
    private func rawOutput(_ route: ContainersRoute, _ containers: HostContainersModel) -> some View {
        if case .inspection = route {
            InspectionJSONScreen(containers: containers)
        } else {
            PodDescribeScreen(containers: containers)
        }
    }

    private func release(old: [ContainersRoute], new: [ContainersRoute]) {
        guard let id = old.first?.hostID else { return }
        let containers = model.containers(for: id)
        if !new.contains(where: \.isLogs) { containers.logs = nil }
        if !new.contains(where: \.isContainer) { containers.inspection = nil }
        if !new.contains(where: \.isPod) { containers.selectedPodID = nil }
    }
}

private extension ContainersRoute {
    var isLogs: Bool {
        if case .logs = self { true } else { false }
    }

    var isContainer: Bool {
        if case .container = self { true } else { false }
    }

    var isPod: Bool {
        if case .pod = self { true } else { false }
    }
}

private extension HostContainersModel {
    /// What was found on the host, once it has been opened.
    var countSummary: String? {
        var parts: [String] = []
        if dockerLoaded { parts.append("\(containers.count) containers") }
        if podsLoaded { parts.append("\(pods.count) pods") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Asks before a Delete or a pod's Stop, and reports an action that failed.
private struct WorkloadPrompts: ViewModifier {
    let containers: HostContainersModel?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                containers?.confirmation?.confirmationTitle ?? "",
                isPresented: Binding(
                    get: { containers?.confirmation != nil },
                    set: { if !$0 { containers?.confirmation = nil } }
                ),
                titleVisibility: .visible,
                presenting: containers?.confirmation
            ) { request in
                Button(request.confirmButtonTitle, role: .destructive) { containers?.perform(request) }
            } message: { request in
                Text(request.confirmationMessage)
            }
            .alert(
                containers?.actionFailure?.title ?? "",
                isPresented: Binding(
                    get: { containers?.actionFailure != nil },
                    set: { if !$0 { containers?.actionFailure = nil } }
                ),
                presenting: containers?.actionFailure
            ) { _ in
                Button("OK") {}
            } message: { failure in
                Text(failure.message)
            }
    }
}

/// Keeps `containers` refreshing while the screen is on and the app is active.
struct WorkloadPolling: ViewModifier {
    let containers: HostContainersModel
    @Environment(MobileModel.self) private var model

    func body(content: Content) -> some View {
        content.task(id: model.activity == .visible) {
            guard model.activity == .visible else { return }
            await containers.poll()
        }
    }
}

/// A label and value in a detail screen.
struct WorkloadFact: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        LabeledContent(label) {
            Text(value)
                .font(Aero.font(.callout))
                .foregroundStyle(Aero.text.primary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(Aero.font(.callout))
        .foregroundStyle(Aero.text.secondary)
    }
}

/// A screen of monospaced text: raw inspect JSON or `kubectl describe`.
struct WorkloadTextScreen: View {
    let title: String
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(Aero.monospacedFont(.footnote))
                .foregroundStyle(Aero.text.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background { SkyBackground() }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Copy", systemImage: "doc.on.doc") { LogTextSurface.copy(text) }
            }
        }
    }
}
