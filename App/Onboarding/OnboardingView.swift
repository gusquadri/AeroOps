import AeroCore
import AeroTheme
import SwiftUI

/// The first-run onboarding sheet: Welcome, first key, first server, MCP setup, Done.
///
/// Shown over the main window while ``OnboardingState/isPresented`` (see ``OnboardingState`` for
/// when). Keys and servers are created right away through the same code as Settings, so Skip
/// keeps everything set up so far. Return continues, Esc skips (asking first only when an
/// unsaved server would be lost), ⌘[ goes back.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var flow: OnboardingFlow
    @State private var pendingDiscard: PendingDiscard?

    /// What would be lost by leaving the server step with an unsaved server.
    private enum PendingDiscard: Identifiable {
        case skipSetup
        case continueWithoutServer
        var id: Self { self }
    }

    /// - Parameter flow: Where to start; a new run starts at Welcome (snapshots start elsewhere).
    init(flow: OnboardingFlow = OnboardingFlow()) {
        _flow = State(initialValue: flow)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding([.horizontal, .top], 24)
                .padding(.bottom, 14)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            navigationBar
                .padding(16)
        }
        .frame(width: 720, height: 620)
        .background { Aero.sky.gradient.ignoresSafeArea() }
        .confirmationDialog(
            "Discard “\(unsavedServerName)”?",
            isPresented: isPresent($pendingDiscard),
            presenting: pendingDiscard
        ) { discard in
            switch discard {
            case .skipSetup:
                Button("Skip Setup", role: .destructive) { skip() }
            case .continueWithoutServer:
                Button("Continue Without It", role: .destructive) { go(to: .agents) }
            }
            Button("Keep Editing", role: .cancel) {}
        } message: { _ in
            Text("This server isn’t added yet. Keys and servers you already set up stay either way.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            OnboardingStepIndicator(current: flow.step)
            VStack(alignment: .leading, spacing: 4) {
                Text(flow.step.title)
                    .font(Aero.font(.title, weight: .semibold))
                    .foregroundStyle(Aero.text.primary)
                    .accessibilityAddTraits(.isHeader)
                Text(flow.step.subtitle)
                    .font(Aero.font(.callout))
                    .foregroundStyle(Aero.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch flow.step {
        case .welcome: OnboardingWelcomeStep()
        case .key: OnboardingKeyStep(flow: flow)
        case .server: OnboardingServerStep(flow: flow)
        case .agents: OnboardingAgentsStep()
        case .done: OnboardingDoneStep(flow: flow)
        }
    }

    // MARK: - Navigation

    private var navigationBar: some View {
        HStack(spacing: 12) {
            if flow.step != .done {
                Button("Skip Setup", action: requestSkip)
                    .buttonStyle(.aquaSecondary)
                    .keyboardShortcut(.cancelAction)
                    .help("Close setup and keep everything set up so far (Esc)")
            }
            Spacer(minLength: 12)
            if let previous = flow.step.previous {
                Button("Back", systemImage: "chevron.left") { go(to: previous) }
                    .buttonStyle(.aquaSecondary)
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Previous step (⌘[)")
            }
            // One primary button at a time: Continue steps back while the step's own owns Return.
            Button(continueTitle, action: advance)
                .buttonStyle(AquaButtonStyle(continueOwnsReturn ? .primary : .secondary))
                .keyboardShortcut(continueOwnsReturn ? .defaultAction : nil)
                .disabled(!canContinue)
                .help(continueHelp)
        }
    }

    private var continueTitle: String {
        switch flow.step {
        case .welcome: "Get Started"
        case .done: "Open Dashboard"
        default: "Continue"
        }
    }

    private var canContinue: Bool {
        switch flow.step {
        case .key: !model.ssh.keys.isEmpty || model.ssh.agentChoice == .system
        default: true
        }
    }

    private var continueHelp: String {
        flow.step == .key && !canContinue
            ? "Generate or import a key first, or turn on “Use system ssh-agent instead”."
            : continueTitle
    }

    /// Return belongs to the step's own primary button while it shows one (Generate Key,
    /// Add Host), else to Continue.
    private var continueOwnsReturn: Bool {
        switch flow.step {
        case .key: flow.currentKey(in: model.ssh.keys) != nil
        case .server: !model.hosts.isEmpty
        default: true
        }
    }

    private var unsavedServerName: String {
        let draft = flow.hostDraft
        return [draft.trimmedName, draft.trimmedAddress, "this server"].first { !$0.isEmpty } ?? "this server"
    }

    /// Whether leaving now would drop a server the user started typing.
    private var wouldLoseServer: Bool {
        model.hosts.isEmpty && flow.hasUnsavedServer
    }

    private func advance() {
        switch flow.step {
        case .done:
            model.selectedTab = .dashboard
            if let id = flow.addedHostID, model.host(id: id) != nil {
                model.selection = id
            }
            model.onboarding.complete()
        case .server where wouldLoseServer:
            pendingDiscard = .continueWithoutServer
        default:
            if let next = flow.step.next { go(to: next) }
        }
    }

    private func go(to step: OnboardingFlow.Step) {
        if step == .server {
            flow.preselectKey(model.ssh.agentChoice == .system ? nil : flow.currentKey(in: model.ssh.keys)?.id)
        }
        flow.isChoosingKey = flow.isChoosingKey && step == .key
        flow.step = step
    }

    private func requestSkip() {
        if wouldLoseServer {
            pendingDiscard = .skipSetup
        } else {
            skip()
        }
    }

    private func skip() {
        model.onboarding.complete()
    }
}

// MARK: - Step indicator

/// Numbered dots for the five steps: done ones ticked, the current one filled.
struct OnboardingStepIndicator: View {
    let current: OnboardingFlow.Step

    var body: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingFlow.Step.allCases) { step in
                if step != .welcome {
                    Capsule()
                        .fill(step <= current ? Aero.aquaDeep : Aero.neutral.opacity(0.5))
                        .frame(width: 22, height: 2)
                }
                HStack(spacing: 6) {
                    badge(step)
                    Text(step.label)
                        .font(Aero.font(.caption, weight: step == current ? .semibold : .regular))
                        .foregroundStyle(step == current ? Aero.text.primary : Aero.text.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current.rawValue + 1) of \(OnboardingFlow.Step.allCases.count): \(current.label)")
    }

    @ViewBuilder
    private func badge(_ step: OnboardingFlow.Step) -> some View {
        ZStack {
            if step < current {
                Circle().fill(Aero.leaf)
                Image(systemName: "checkmark")
                    .font(Aero.font(size: 9, weight: .bold))
                    .foregroundStyle(Aero.text.onBright)
            } else if step == current {
                AquaGel()
                Text(verbatim: "\(step.rawValue + 1)")
                    .font(Aero.font(size: 10, weight: .bold))
                    .foregroundStyle(Aero.text.onAccent)
            } else {
                Circle().fill(Aero.glass.solidFill)
                Circle().strokeBorder(Aero.neutral, lineWidth: 1)
                Text(verbatim: "\(step.rawValue + 1)")
                    .font(Aero.font(size: 10, weight: .semibold))
                    .foregroundStyle(Aero.text.secondary)
            }
        }
        .frame(width: 18, height: 18)
    }
}

// MARK: - Previews

#Preview("Onboarding · welcome") {
    OnboardingView()
        .environment(AppModel.preview(hosts: []))
}

#Preview("Onboarding · key") {
    OnboardingView(flow: OnboardingFlow(step: .key))
        .environment(AppModel.preview(hosts: []))
}

#Preview("Onboarding · server") {
    OnboardingView(flow: OnboardingFlow(step: .server))
        .environment(AppModel.preview(hosts: []))
}
