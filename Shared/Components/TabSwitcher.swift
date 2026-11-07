import AeroTheme
import SwiftUI

/// A tab a ``TabSwitcher`` can show.
protocol SwitcherTab: Hashable, Identifiable {
    var title: String { get }
    /// SF Symbol for the tab.
    var systemImage: String { get }
    /// The pointer tooltip.
    var help: String { get }
}

extension SwitcherTab {
    var help: String { title }
}

/// The main window's tab switcher: one segment per tab, each with its SF Symbol and title.
/// The selected tab is a lit gel pill (aqua by day, violet by night) that slides between tabs.
/// The Mac app's toolbar and the iOS app's split layout (an unfolded iPhone Duo) both use it.
///
/// Custom rather than a segmented `Picker`: on macOS a segmented control shows a `Label`'s
/// title or its icon, never both.
struct TabSwitcher<Tab: SwitcherTab>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                segment(tab)
            }
        }
        .padding(2)
        .fixedSize()
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Section")
    }

    private func segment(_ tab: Tab) -> some View {
        let isSelected = tab == selection
        return Button {
            selection = tab
        } label: {
            Label(tab.title, systemImage: tab.systemImage)
                .labelStyle(.titleAndIcon)
                .font(Aero.font(Self.textStyle, weight: .medium))
                .foregroundStyle(isSelected ? Aero.text.onAccent : Aero.text.primary)
                .padding(.horizontal, Self.horizontalPadding)
                .padding(.vertical, Self.verticalPadding)
                .background {
                    if isSelected {
                        AquaGel()
                            .matchedGeometryEffect(id: "selection", in: highlight)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tab.help)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    #if os(macOS)
    private static var textStyle: Font.TextStyle { .body }
    private static var horizontalPadding: CGFloat { 12 }
    private static var verticalPadding: CGFloat { 5 }
    #else
    /// Smaller than the body text an iPhone uses, so every title still fits beside a widened
    /// sidebar; and taller, for a finger.
    private static var textStyle: Font.TextStyle { .subheadline }
    private static var horizontalPadding: CGFloat { 10 }
    private static var verticalPadding: CGFloat { 8 }
    #endif
}
