import CoreGraphics

/// Fits the columns of a Containers-tab table to its width.
///
/// SwiftUI's `Table` is an `NSTableView` (inset style: 16 pt side insets, 17 pt between
/// columns) that spreads a resize evenly over its resizable columns. It never hands out the
/// width of a column that goes away, ignores new ideal widths once it exists, and a new table
/// whose ideal widths are too wide scrolls sideways instead of shrinking. So the tables:
/// - give columns with short content (counts, ages, status chips, row buttons) a fixed width;
/// - drop optional columns, most expendable first, before Name gets narrower than
///   `nameComfort`;
/// - pass ``width(_:)`` as each column's ideal width: Name gets what the other columns leave,
///   so a new table exactly fills its width; and
/// - rebuild with `.id(layout.identity)` when the columns or their fixed widths change. Plain
///   resizes keep the table, which shares the change out itself.
struct WorkloadTableLayout<Column: Hashable> {
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

    /// What decides whether the table must be rebuilt: the shown columns and their minimum
    /// widths (a fixed column's width).
    struct Identity: Hashable {
        var columns: [Column]
        var minimums: [CGFloat]
    }

    /// NSTableView's inset style: 16 pt on each side.
    static var insets: CGFloat { 32 }
    /// NSTableView's intercell spacing.
    static var spacing: CGFloat { 17 }
    /// Room for a legacy (always shown) vertical scroller, which narrows the table.
    static var scrollerAllowance: CGFloat { 16 }

    let identity: Identity
    private let widths: [Column: CGFloat]

    /// - Parameters:
    ///   - width: the table's width.
    ///   - columns: every column in display order, Name included.
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

        // Everything at its minimum; spare width to Name up to its comfort width, then to the
        // other columns up to their ideal width (in proportion), then the rest to Name.
        var widths = Dictionary(uniqueKeysWithValues: shown.map { ($0.column, $0.min) })
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

        identity = Identity(columns: shown.map(\.column), minimums: shown.map(\.min))
        self.widths = widths
    }

    func shows(_ column: Column) -> Bool {
        widths[column] != nil
    }

    /// The column's ideal width for a new table.
    func width(_ column: Column) -> CGFloat {
        widths[column] ?? 0
    }
}
