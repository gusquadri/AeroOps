import SwiftUI

/// A titled glass card: a header row (optional SF Symbol, title, trailing accessory) over a
/// glossy divider, then the content. For Settings panes, the Activity screen (pending
/// approvals, audit log) and host detail.
///
/// ```swift
/// GlassSection("Pending approvals", systemImage: "hand.raised") {
///     ForEach(requests) { ApprovalRow(request: $0) }
/// } accessory: {
///     AeroTag("\(requests.count)")
/// }
/// ```
public struct GlassSection<Content: View, Accessory: View>: View {
    private let title: String
    private let systemImage: String?
    private let content: Content
    private let accessory: Accessory

    private var accessibility = AeroAccessibility()

    /// A section with a trailing `accessory` in the header (a button, tag or count).
    public init(
        _ title: String,
        systemImage: String? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
        self.accessory = accessory()
    }

    /// The section.
    public var body: some View {
        AeroCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(Aero.font(.headline, weight: .semibold))
                            .foregroundStyle(Aero.aquaDeep)
                            .accessibilityHidden(true)
                    }
                    Text(title)
                        .font(Aero.font(.headline, weight: .semibold))
                        .foregroundStyle(Aero.text.primary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    accessory
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)

                // Etched divider: an ink line over a white line.
                VStack(spacing: 0) {
                    Rectangle().fill(Aero.ink.opacity(accessibility.increaseContrast ? 0.35 : 0.12))
                    Rectangle().fill(.white.opacity(0.7))
                }
                .frame(height: 2)
                .padding(.horizontal, 10)

                content
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

extension GlassSection where Accessory == EmptyView {
    /// A section without a header accessory.
    public init(_ title: String, systemImage: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, systemImage: systemImage, content: content, accessory: { EmptyView() })
    }
}

// MARK: - Previews

#Preview("GlassSection") {
    VStack(spacing: 20) {
        GlassSection("Pending approvals", systemImage: "hand.raised.fill") {
            HStack {
                StatusOrb(tone: .warning)
                Text("claude-code wants to run `docker restart api`")
                    .font(Aero.font(.callout))
                Spacer()
                Button("Deny", role: .destructive) {}.buttonStyle(.aqua).controlSize(.small)
                Button("Approve") {}.buttonStyle(.aqua).controlSize(.small)
            }
        } accessory: {
            AeroTag("1 pending", tone: .warning)
        }
        GlassSection("Audit log") {
            Text("No activity yet")
                .font(Aero.font(.callout))
                .foregroundStyle(Aero.text.secondary)
        }
    }
    .frame(width: 560)
    .padding(40)
    .background { SkyBackground() }
}
