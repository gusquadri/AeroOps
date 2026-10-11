import SwiftUI

/// Menu commands: File › New Host… (⌘N) and View › Dashboard…Activity (⌘1–⌘4).
struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Host…") {
                openWindow(id: AeroOpsApp.mainWindowID)
                model.requestNewHost()
            }
            .keyboardShortcut("n")
        }
        CommandGroup(before: .toolbar) {
            ForEach(AppTab.allCases) { tab in
                Button(tab.title) {
                    openWindow(id: AeroOpsApp.mainWindowID)
                    model.selectedTab = tab
                }
                .keyboardShortcut(KeyEquivalent(tab.shortcutDigit), modifiers: .command)
            }
            Divider()
        }
    }
}
