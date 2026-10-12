/// The four main-window tabs. Shown as a segmented control in the
/// toolbar and bound to ⌘1–⌘4 in the View menu.
enum AppTab: String, CaseIterable, Identifiable, Sendable {
    case dashboard
    case containers
    case terminals
    case activity

    var id: Self { self }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .containers: "Containers"
        case .terminals: "Terminals"
        case .activity: "Activity"
        }
    }

    /// SF Symbol for the tab.
    var systemImage: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .containers: "shippingbox"
        case .terminals: "terminal"
        case .activity: "list.bullet.rectangle"
        }
    }

    /// The digit of the tab's ⌘-shortcut: ⌘1 for the first tab, and so on.
    var shortcutDigit: Character {
        switch self {
        case .dashboard: "1"
        case .containers: "2"
        case .terminals: "3"
        case .activity: "4"
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
