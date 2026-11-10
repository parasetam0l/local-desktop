import SwiftUI

/// The look of everything drawn over the Mac's picture during a session: solid dark
/// panels with a thin border and one blue accent. Solid rather than a material, so the
/// controls read the same over any Mac content.
enum SessionStyle {
    static let panel = Color(red: 0.11, green: 0.12, blue: 0.14)
    static let bar = Color(red: 0.15, green: 0.16, blue: 0.18)
    static let raised = Color.white.opacity(0.11)
    static let hairline = Color.white.opacity(0.16)
    static let accent = Color(red: 0.22, green: 0.54, blue: 0.87)
    static let secondaryText = Color.white.opacity(0.6)
    static let danger = Color(red: 0.96, green: 0.45, blue: 0.43)
}

extension View {
    /// A solid dark surface with a hairline border, for floating session controls.
    func sessionSurface<S: InsettableShape>(_ shape: S) -> some View {
        background(SessionStyle.panel.opacity(0.94), in: shape)
            .overlay(shape.strokeBorder(SessionStyle.hairline, lineWidth: 0.5))
    }
}

extension View {
    /// A solid group surface: `raised` fill, 12 pt continuous corners, hairline border.
    func sessionCard(cornerRadius: CGFloat = 12) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(SessionStyle.raised, in: shape)
            .overlay(shape.strokeBorder(SessionStyle.hairline, lineWidth: 0.5))
    }

    /// The page treatment of the dark screens: solid panel, white text, blue accent.
    func sessionPage() -> some View {
        background(SessionStyle.panel.ignoresSafeArea())
            .foregroundStyle(.white)
            .tint(SessionStyle.accent)
            .preferredColorScheme(.dark)
            .presentationBackground(SessionStyle.panel)
    }
}

/// A solid button: `raised` with white text by default, the blue accent when
/// `prominent` (one per screen at most), red text when `destructive`.
struct SessionButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false
    var compact = false
    var fullWidth = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration.label
            .font(compact ? .footnote.weight(.medium) : .subheadline.weight(.medium))
            .foregroundStyle(destructive ? SessionStyle.danger : Color.white)
            .padding(.horizontal, compact ? 10 : 16)
            .padding(.vertical, compact ? 6 : 11)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(prominent ? SessionStyle.accent : SessionStyle.raised, in: shape)
            .overlay(shape.strokeBorder(SessionStyle.hairline, lineWidth: prominent ? 0 : 0.5))
            .opacity(configuration.isPressed ? 0.7 : (isEnabled ? 1 : 0.45))
    }
}

/// A short message at the top of the session screen that goes away by itself.
struct SessionToast: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
            Text(text)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .sessionSurface(Capsule())
        .accessibilityElement(children: .combine)
    }
}
