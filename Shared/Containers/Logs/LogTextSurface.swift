import AeroTheme
import SwiftUI
#if os(macOS)
import AppKit
typealias LogPlatformColor = NSColor
typealias LogPlatformFont = NSFont
#else
import UIKit
typealias LogPlatformColor = UIColor
typealias LogPlatformFont = UIFont
#endif

/// The fonts and colours of log text, resolved for the platform's text view.
@MainActor
enum LogTextStyle {
    static let text = LogPlatformColor(Aero.text.primary)
    static let timestamp = LogPlatformColor(Aero.text.secondary)
    static let info = LogPlatformColor(Aero.aquaDeep)
    static let background = LogPlatformColor(Aero.glass.solidFill)
    static let selection = LogPlatformColor(Aero.aqua).withAlphaComponent(0.3)
    static let match = adaptive { variant in
        LogPlatformColor(Aero.sun).withAlphaComponent(variant == .night ? 0.2 : 0.45)
    }
    /// Full sun by day. By night the text is light, so the current match is a stronger tint
    /// that light text still reads on.
    static let currentMatch = adaptive { variant in
        variant == .night ? LogPlatformColor(Aero.sun).withAlphaComponent(0.42) : LogPlatformColor(Aero.sun)
    }

    /// Monospaced, so log text aligns in columns.
    static var font: LogPlatformFont {
        #if os(macOS)
        Aero.monospacedNSFont(.callout)
        #else
        Aero.monospacedUIFont(.footnote)
        #endif
    }

    private static func adaptive(_ resolve: @escaping @Sendable (AeroVariant) -> LogPlatformColor) -> LogPlatformColor {
        #if os(macOS)
        NSColor(name: nil) { resolve(AeroVariant($0)) }
        #else
        UIColor { resolve($0.userInterfaceStyle == .dark ? .night : .day) }
        #endif
    }
}

/// The text system below ``LogTextSurface``: TextKit 1 with non-contiguous layout, so appending
/// to a long log does not lay out what is already there.
@MainActor
struct LogTextStack {
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))

    init() {
        container.widthTracksTextView = true
        layout.allowsNonContiguousLayout = true
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
    }
}

#if os(macOS)
/// A read-only `NSTextView` in a scroll view, over the text in ``storage``.
@MainActor
final class LogTextSurface: NSObject, NSTextViewDelegate {
    let view = NSScrollView()
    var onSelectionChange: (() -> Void)?

    private let stack = LogTextStack()
    private let textView: NSTextView

    override init() {
        textView = NSTextView(frame: .zero, textContainer: stack.container)
        super.init()
        stack.layout.backgroundLayoutEnabled = true
        configureBehaviour()
        configureAppearance()
        textView.delegate = self
        view.documentView = textView
        view.hasVerticalScroller = true
        view.hasHorizontalScroller = false
        view.autohidesScrollers = true
        view.drawsBackground = true
        view.backgroundColor = LogTextStyle.background
        view.borderType = .noBorder
    }

    private func configureBehaviour() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = false
        textView.allowsUndo = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel("Log lines")
    }

    private func configureAppearance() {
        textView.drawsBackground = true
        textView.backgroundColor = LogTextStyle.background
        textView.textColor = LogTextStyle.text
        textView.font = LogTextStyle.font
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.selectedTextAttributes = [.backgroundColor: LogTextStyle.selection]
    }

    var storage: NSTextStorage { stack.storage }
    var selectedRange: NSRange { textView.selectedRange() }

    var isPinnedToBottom: Bool {
        guard let document = view.documentView else { return true }
        let visible = view.contentView.documentVisibleRect
        return visible.maxY >= document.bounds.maxY - 24 || document.bounds.height <= visible.height
    }

    func scrollToBottom() {
        textView.scrollToEndOfDocument(nil)
    }

    func reveal(_ range: NSRange) {
        textView.scrollRangeToVisible(range)
        textView.showFindIndicator(for: range)
    }

    static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        onSelectionChange?()
    }
}

/// Hosts a ``LogTextController``'s scroll view in SwiftUI. The controller, not SwiftUI, drives
/// the content, so new lines never re-render the SwiftUI hierarchy.
struct LogTextView: NSViewRepresentable {
    let controller: LogTextController

    func makeNSView(context: Context) -> NSScrollView {
        controller.surface.view
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
#else
/// A read-only `UITextView` over the text in ``storage``.
@MainActor
final class LogTextSurface: NSObject, UITextViewDelegate {
    let view: UITextView
    var onSelectionChange: (() -> Void)?

    private let stack = LogTextStack()

    override init() {
        view = UITextView(frame: .zero, textContainer: stack.container)
        super.init()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = LogTextStyle.background
        view.textColor = LogTextStyle.text
        view.font = LogTextStyle.font
        view.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.tintColor = LogTextStyle.info
        view.alwaysBounceVertical = true
        view.accessibilityLabel = "Log lines"
        view.delegate = self
    }

    var storage: NSTextStorage { stack.storage }
    var selectedRange: NSRange { view.selectedRange }

    var isPinnedToBottom: Bool {
        let bottom = view.contentSize.height + view.adjustedContentInset.bottom
        return view.contentOffset.y + view.bounds.height >= bottom - 24 || view.contentSize.height <= view.bounds.height
    }

    func scrollToBottom() {
        view.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
    }

    func reveal(_ range: NSRange) {
        view.scrollRangeToVisible(range)
    }

    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        onSelectionChange?()
    }
}

/// Hosts a ``LogTextController``'s text view in SwiftUI. The controller, not SwiftUI, drives
/// the content, so new lines never re-render the SwiftUI hierarchy.
struct LogTextView: UIViewRepresentable {
    let controller: LogTextController

    func makeUIView(context: Context) -> UITextView {
        controller.surface.view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {}
}
#endif
