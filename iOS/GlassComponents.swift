import SwiftUI

// MARK: - Glass Button Style

enum GlassButtonVariant {
    case primary
    case secondary
    case tinted(Color)
    case destructive
}

struct GlassButtonStyle: ButtonStyle {
    var variant: GlassButtonVariant = .secondary
    var size: ControlSize = .regular
    var isFullWidth: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(fontForSize)
            .fontWeight(.semibold)
            .foregroundStyle(foregroundColor(isPressed: configuration.isPressed))
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .background {
                backgroundShape
                    .fill(backgroundColor(isPressed: configuration.isPressed))
                    .background(.ultraThinMaterial, in: backgroundShape)
            }
            .overlay {
                backgroundShape
                    .stroke(borderGradient(isPressed: configuration.isPressed), lineWidth: 0.75)
            }
            .shadow(color: shadowColor(isPressed: configuration.isPressed), radius: configuration.isPressed ? 2 : 6, y: configuration.isPressed ? 1 : 3)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }

    private var backgroundShape: some InsettableShape {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var cornerRadius: CGFloat {
        switch size {
        case .mini: return 8
        case .small: return 10
        case .regular: return 14
        case .large, .extraLarge: return 16
        @unknown default: return 14
        }
    }

    private var fontForSize: Font {
        switch size {
        case .mini: return .caption2
        case .small: return .caption
        case .regular: return .subheadline
        case .large, .extraLarge: return .body
        @unknown default: return .subheadline
        }
    }

    private var horizontalPadding: CGFloat {
        switch size {
        case .mini: return 10
        case .small: return 12
        case .regular: return 18
        case .large, .extraLarge: return 22
        @unknown default: return 18
        }
    }

    private var verticalPadding: CGFloat {
        switch size {
        case .mini: return 5
        case .small: return 7
        case .regular: return 11
        case .large, .extraLarge: return 14
        @unknown default: return 11
        }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        switch variant {
        case .primary:
            return Color.blue.opacity(isPressed ? 0.45 : 0.35)
        case .secondary:
            return Color.white.opacity(isPressed ? 0.22 : 0.12)
        case .tinted(let color):
            return color.opacity(isPressed ? 0.45 : 0.30)
        case .destructive:
            return Color.red.opacity(isPressed ? 0.4 : 0.25)
        }
    }

    private func foregroundColor(isPressed: Bool) -> Color {
        switch variant {
        case .primary, .tinted, .destructive:
            return .white
        case .secondary:
            return .white.opacity(isPressed ? 0.8 : 0.95)
        }
    }

    private func borderGradient(isPressed: Bool) -> LinearGradient {
        let opacityTop: Double = isPressed ? 0.25 : 0.45
        let opacityBottom: Double = isPressed ? 0.08 : 0.15
        return LinearGradient(
            colors: [Color.white.opacity(opacityTop), Color.white.opacity(opacityBottom)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func shadowColor(isPressed: Bool) -> Color {
        switch variant {
        case .primary:
            return Color.blue.opacity(isPressed ? 0.15 : 0.3)
        case .tinted(let color):
            return color.opacity(isPressed ? 0.15 : 0.3)
        case .destructive:
            return Color.red.opacity(isPressed ? 0.15 : 0.3)
        case .secondary:
            return Color.black.opacity(isPressed ? 0.1 : 0.2)
        }
    }
}

// MARK: - Glass Card Modifier

struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 20
    var opacity: Double = 0.12
    var shadowRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(opacity))
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.35), Color.white.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            }
            .shadow(color: Color.black.opacity(0.3), radius: shadowRadius, y: shadowRadius / 2)
    }
}

// MARK: - View Extensions

extension View {
    func glassCard(cornerRadius: CGFloat = 20, opacity: Double = 0.12, shadowRadius: CGFloat = 16) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, opacity: opacity, shadowRadius: shadowRadius))
    }

    func glassButton(variant: GlassButtonVariant = .secondary, size: ControlSize = .regular, isFullWidth: Bool = false) -> some View {
        buttonStyle(GlassButtonStyle(variant: variant, size: size, isFullWidth: isFullWidth))
    }
}
