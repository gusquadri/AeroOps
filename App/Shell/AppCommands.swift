import AppKit
import SwiftUI
import TerminalKit

/// Menu commands.
///
/// - File: New Host… (⌘N), Import Hosts from ~/.ssh/config…, Import Hosts from Termius…,
///   New Terminal Tab (⌘T), and Close (⌘W), which closes the shown terminal tab (asking
///   first while it runs) or else the key window.
/// - View: Dashboard…Activity (⌘1–⌘5).
/// - Terminal: next / previous tab (⌃Tab / ⌃⇧Tab), Reconnect, font size (⌘+ / ⌘− / ⌘0) and
///   tabs 1…9 (⌘⌥1…⌘⌥9). They act while the main window shows terminal tabs.
///
/// Copy, Paste and Select All stay in the standard Edit menu and reach the focused terminal
/// through the responder chain.
struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.terminalTabs) private var terminalTabs

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Host…") {
                openWindow(id: AeroOpsApp.mainWindowID)
                model.requestNewHost()
            }
            .keyboardShortcut("n")
            Button("Import Hosts from ~/.ssh/config…") {
                openWindow(id: AeroOpsApp.mainWindowID)
                model.requestSSHConfigImport()
            }
            Button("Import Hosts from Termius…") {
                openWindow(id: AeroOpsApp.mainWindowID)
                model.requestTermiusImport()
            }
            Button("New Terminal Tab") {
                guard let host = model.newTerminalTabHost else { return NSSound.beep() }
                openWindow(id: AeroOpsApp.mainWindowID)
                model.openSSH(host)
            }
            .keyboardShortcut("t")
        }
        CommandGroup(replacing: .saveItem) {
            Button(terminalTabs == nil ? "Close" : "Close Tab") {
                if let terminalTabs, let session = terminalTabs.selectedSession, NSApp.keyWindow?.isSheet != true {
                    terminalTabs.requestClose(session.id)
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w")
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
        CommandMenu("Terminal") {
            Button("Show Next Tab") { terminalTabs?.cycle(by: 1) }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(terminalTabs == nil)
            Button("Show Previous Tab") { terminalTabs?.cycle(by: -1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(terminalTabs == nil)
            Button("Reconnect") {
                if let terminalTabs, let session = terminalTabs.selectedSession {
                    terminalTabs.reconnect(session.id)
                }
            }
            .disabled(terminalTabs == nil)
            Divider()
            Button("Bigger") { terminalTabs?.selectedSession?.increaseFontSize() }
                .keyboardShortcut("+")
                .disabled(terminalTabs == nil)
            Button("Smaller") { terminalTabs?.selectedSession?.decreaseFontSize() }
                .keyboardShortcut("-")
                .disabled(terminalTabs == nil)
            Button("Actual Size") { terminalTabs?.selectedSession?.resetFontSize() }
                .keyboardShortcut("0")
                .disabled(terminalTabs == nil)
            Divider()
            ForEach(1...9, id: \.self) { number in
                Button("Show Tab \(number)") { terminalTabs?.select(index: number - 1) }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: [.command, .option])
                    .disabled(terminalTabs == nil)
            }
        }
    }
}
