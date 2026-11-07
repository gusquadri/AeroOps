/// The five main-window tabs. Shown with their symbols in the
/// toolbar's tab switcher and bound to ⌘1–⌘5 in the View menu. ``activity`` is shown as "MCPs".
enum AppTab: String, CaseIterable, Identifiable, Sendable, SwitcherTab {
    case dashboard
    case containers
    case terminals
    case files
    case activity

    var id: Self { self }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .containers: "Containers"
        case .terminals: "Terminals"
        case .files: "Files"
        case .activity: "MCPs"
        }
    }

    /// SF Symbol for the tab.
    var systemImage: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .containers: "shippingbox"
        case .terminals: "terminal"
        case .files: "folder"
        case .activity: "point.3.filled.connected.trianglepath.dotted"
        }
    }

    var help: String { "\(title) (⌘\(String(shortcutDigit)))" }

    /// The digit of the tab's ⌘-shortcut: ⌘1 for the first tab, and so on.
    var shortcutDigit: Character {
        switch self {
        case .dashboard: "1"
        case .containers: "2"
        case .terminals: "3"
        case .files: "4"
        case .activity: "5"
        }
    }
}

/// Panes of the Settings window (Hosts, Keys, MCP, Appearance), plus
/// Updates (Sparkle).
enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case hosts
    case keys
    case mcp
    case appearance
    case updates

    var id: Self { self }

    var title: String {
        switch self {
        case .hosts: "Hosts"
        case .keys: "Keys"
        case .mcp: "MCP"
        case .appearance: "Appearance"
        case .updates: "Updates"
        }
    }

    /// SF Symbol for the pane's toolbar tab.
    var systemImage: String {
        switch self {
        case .hosts: "server.rack"
        case .keys: "key"
        case .mcp: "point.3.connected.trianglepath.dotted"
        case .appearance: "paintpalette"
        case .updates: "arrow.triangle.2.circlepath"
        }
    }
}
