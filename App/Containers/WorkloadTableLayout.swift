import SwiftUI

/// Fits the columns of a Containers-tab table to its width.
///
/// SwiftUI's `Table` is an `NSTableView` (inset style: 16 pt side insets, 17 pt between
/// columns) that spreads a resize evenly over its resizable columns. It doesn't hand out the
/// width of a column that is removed, and it ignores new ideal or fixed widths once it exists;
/// hiding or showing a column (`TableColumnCustomization` visibility) does share the width out
/// again. So the tables:
/// - declare every column once, with its ``Column`` raw value as customization ID, and hide
///   the ones the layout leaves out (``apply(to:)``) instead of adding and removing columns;
/// - give columns with short content (counts, ages, status chips, row buttons) a fixed width;
///   a column whose width depends on state (a wider Status, fewer row buttons) is two columns,
///   one of them hidden;
/// - hide optional columns, most expendable first, before Name gets narrower than
///   `nameComfort`; and
/// - are created once their width is known, with ``width(_:)`` as each column's ideal width, so
///   they start out exactly filled. Name takes what the other columns leave, and is the only
///   column without a maximum width, so it also takes the spare width when the table grows.
struct WorkloadTableLayout<Column: Hashable & CaseIterable & RawRepresentable> where Column.RawValue == String {
    /// One column: the width it needs, and the width it grows to before spare width goes to
    /// Name (equal for fixed columns).
    struct Spec {
        var column: Column
        var min: CGFloat
        var ideal: CGFloat

        /// A fixed-width column.
        init(_ column: Column, width: CGFloat) {
            self.init(column, min: width, ideal: width)
        }

        init(_ column: Column, min: CGFloat, ideal: CGFloat) {
            self.column = column
            self.min = min
            self.ideal = ideal
        }
    }

    /// NSTableView's inset style: 16 pt on each side.
    static var insets: CGFloat { 32 }
    /// NSTableView's intercell spacing.
    static var spacing: CGFloat { 17 }
    /// Room for a legacy (always shown) vertical scroller, which narrows the table. When there
    /// is none, the new table grows Name by this much.
    static var scrollerAllowance: CGFloat { 16 }

    /// The columns to show.
    let shown: Set<Column>
    private let widths: [Column: CGFloat]

    /// - Parameters:
    ///   - width: the table's width.
    ///   - columns: the candidate columns, Name included; columns left out stay hidden.
    ///   - name: the column that takes the spare width.
    ///   - nameComfort: the width Name keeps before optional columns give way.
    ///   - dropOrder: optional columns, most expendable first.
    init(width: CGFloat, columns: [Spec], name: Column, nameComfort: CGFloat, dropOrder: [Column]) {
        var shown = columns
        /// Width of everything but Name's own minimum.
        func overhead() -> CGFloat {
            let others = shown.filter { $0.column != name }.reduce(0) { $0 + $1.min }
            return Self.insets + Self.scrollerAllowance + Self.spacing * CGFloat(max(0, shown.count - 1)) + others
        }
        for column in dropOrder where overhead() + nameComfort > width {
            shown.removeAll { $0.column == column }
        }

        var widths = Dictionary(uniqueKeysWithValues: columns.map { ($0.column, $0.ideal) })
        for spec in shown { widths[spec.column] = spec.min }
        let nameMin = shown.first { $0.column == name }?.min ?? 0
        var spare = max(0, width - overhead() - nameMin)
        let toName = min(spare, max(0, nameComfort - nameMin))
        widths[name, default: 0] += toName
        spare -= toName
        let wants = shown.filter { $0.column != name && $0.ideal > $0.min }
        let wanted = wants.reduce(0) { $0 + ($1.ideal - $1.min) }
        if wanted > 0 {
            let share = min(1, spare / wanted)
            for spec in wants {
                widths[spec.column, default: 0] += (spec.ideal - spec.min) * share
            }
            spare -= min(spare, wanted)
        }
        widths[name, default: 0] += spare

        self.shown = Set(shown.map(\.column))
        self.widths = widths
    }

    func shows(_ column: Column) -> Bool {
        shown.contains(column)
    }

    /// The column's ideal width for a new table.
    func width(_ column: Column) -> CGFloat {
        widths[column] ?? 0
    }

    /// Shows the layout's columns and hides the rest.
    func apply<Row: Identifiable>(to customization: inout TableColumnCustomization<Row>) {
        for column in Column.allCases {
            let visibility: Visibility = shows(column) ? .visible : .hidden
            if customization[visibility: column.rawValue] != visibility {
                customization[visibility: column.rawValue] = visibility
            }
        }
    }
}

extension TableColumnContent {
    /// Makes this the table's `column` for ``WorkloadTableLayout/apply(to:)``. Only the layout
    /// shows and hides it; it can't be hidden or moved by hand.
    func layoutColumn<Column: RawRepresentable>(
        _ column: Column
    ) -> some TableColumnContent<TableRowValue, TableColumnSortComparator> where Column.RawValue == String {
        customizationID(column.rawValue)
            .disabledCustomizationBehavior([.visibility, .reorder])
    }
}
