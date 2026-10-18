import AeroTheme
import SwiftUI

/// A single line of host tags as ``AeroTag`` capsules: the first `limit` tags, then "+N" for
/// the rest.
struct TagRow: View {
    let tags: [String]
    var limit = 3

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tags.prefix(limit), id: \.self) { AeroTag($0) }
            if tags.count > limit {
                AeroTag("+\(tags.count - limit)", tint: Aero.neutral)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tags: \(tags.joined(separator: ", "))")
    }
}

#Preview("Tags") {
    VStack(alignment: .leading, spacing: 8) {
        TagRow(tags: ["prod"])
        TagRow(tags: ["prod", "web", "eu-west", "k8s", "db"])
    }
    .padding()
    .background { SkyBackground() }
}
