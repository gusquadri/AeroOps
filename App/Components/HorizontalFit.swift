import SwiftUI

/// `ViewThatFits(in: .horizontal)` for views whose width changes often: it takes the width it
/// is offered and shows the first variant whose ideal width fits it, or the last.
///
/// `ViewThatFits` measures every variant again for each new width. On the Dashboard that is
/// every frame of the sidebar or the inspector sliding, in every card, and it made those
/// animations stutter. This measures each variant's ideal width once, in hidden copies laid out
/// at their ideal size (which a new width does not change), so a new width only compares
/// numbers, and only the shown variant is laid out.
///
/// ```swift
/// HorizontalFit([4, 3, 2, 1]) { limit in
///     TagRow(tags: host.tags, limit: limit)
/// }
/// ```
struct HorizontalFit<Variant: Hashable, Content: View>: View {
    /// Widest first.
    let variants: [Variant]
    let content: (Variant) -> Content

    @State private var idealWidths: [Variant: CGFloat] = [:]
    @State private var shown: Variant?
    /// Kept outside SwiftUI's state, so a new width updates the view only when it changes the
    /// variant.
    @State private var offered = OfferedWidth()

    init(_ variants: [Variant], @ViewBuilder content: @escaping (Variant) -> Content) {
        precondition(!variants.isEmpty, "HorizontalFit needs at least one variant")
        self.variants = variants
        self.content = content
    }

    var body: some View {
        content(shown ?? variants[0])
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                offered.width = width
                choose()
            }
            .background(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(variants, id: \.self) { variant in
                        content(variant)
                            .fixedSize()
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                                idealWidths[variant] = width
                                choose()
                            }
                    }
                }
                .fixedSize()
                .hidden()
                .disabled(true)
                .accessibilityHidden(true)
            }
    }

    /// Shows the first variant that fits the offered width, or the last, once every variant is
    /// measured.
    private func choose() {
        guard let width = offered.width, variants.allSatisfy({ idealWidths[$0] != nil }) else { return }
        let fit = variants.first { idealWidths[$0, default: .infinity] <= width } ?? variants[variants.count - 1]
        if fit != shown {
            shown = fit
        }
    }
}

private final class OfferedWidth {
    var width: CGFloat?
}
