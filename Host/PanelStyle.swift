import SwiftUI
import AppKit

/// The menu bar panel's look, matching the iOS app's session and settings screens
/// (`SessionStyle` there): a solid panel, rounded `raised` groups with hairlines between
/// the rows, quiet section titles and one blue accent. The iOS screens are dark only; here
/// every token also has a light value so the panel follows the Mac's appearance.
enum PanelStyle {
    static let panel = adaptive(light: NSColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1),
                                dark: NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1))
    static let raised = adaptive(light: .white,
                                 dark: NSColor(white: 1, alpha: 0.11))
    static let hairline = adaptive(light: NSColor(white: 0, alpha: 0.1),
                                   dark: NSColor(white: 1, alpha: 0.16))
    static let accent = adaptive(light: NSColor(red: 0.16, green: 0.47, blue: 0.82, alpha: 1),
                                 dark: NSColor(red: 0.22, green: 0.54, blue: 0.87, alpha: 1))
    static let primaryText = adaptive(light: NSColor(white: 0.1, alpha: 1),
                                      dark: .white)
    static let secondaryText = adaptive(light: NSColor(white: 0, alpha: 0.55),
                                        dark: NSColor(white: 1, alpha: 0.6))
    static let danger = adaptive(light: NSColor(red: 0.84, green: 0.23, blue: 0.21, alpha: 1),
                                 dark: NSColor(red: 0.96, green: 0.45, blue: 0.43, alpha: 1))

    /// iOS rows are 46 pt at 15 pt text; this is the same proportion at the Mac's 13 pt.
    static let rowHeight: CGFloat = 36
    static let cornerRadius: CGFloat = 12

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

extension View {
    /// A `raised` group surface: 12 pt continuous corners and a hairline border.
    func panelCard(cornerRadius: CGFloat = PanelStyle.cornerRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(PanelStyle.raised, in: shape)
            .overlay(shape.strokeBorder(PanelStyle.hairline, lineWidth: 0.5))
    }

    /// A tinted notice surface (setup, update, error), shaped like a group.
    func panelNotice(_ tint: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: PanelStyle.cornerRadius, style: .continuous)
        return padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.12), in: shape)
            .overlay(shape.strokeBorder(tint.opacity(0.35), lineWidth: 0.5))
    }
}

/// A titled group of rows on one rounded surface, with hairlines between the rows.
struct PanelSection<Content: View>: View {
    let title: String
    let footer: String?
    var footerIsWarning = false
    @ViewBuilder let content: Content

    init(_ title: String, footer: String? = nil, footerIsWarning: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.footerIsWarning = footerIsWarning
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(PanelStyle.secondaryText)
                .padding(.horizontal, 4)
            _VariadicView.Tree(PanelRowsLayout()) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelCard()
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(footerIsWarning ? PanelStyle.danger : PanelStyle.secondaryText)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Stacks a section's rows and draws a hairline between each two.
private struct PanelRowsLayout: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        VStack(spacing: 0) {
            ForEach(children) { child in
                child
                if child.id != last {
                    Hairline()
                        .padding(.leading, 14)
                }
            }
        }
    }
}

/// One device pixel of `hairline`, so it never lands between pixels and disappears.
private struct Hairline: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(PanelStyle.hairline)
            .frame(height: 1 / max(displayScale, 1))
    }
}

/// One row of a section: 14 pt side insets, at least `rowHeight` tall.
struct PanelRow<Content: View>: View {
    var verticalPadding: CGFloat = 0
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .font(.body)
            .padding(.horizontal, 14)
            .padding(.vertical, verticalPadding)
            .frame(minHeight: PanelStyle.rowHeight)
    }
}

/// "Title ……… value" row: the title in primary text, the value trailing.
struct PanelValueRow<Value: View>: View {
    let title: String
    @ViewBuilder let value: Value

    init(_ title: String, @ViewBuilder value: () -> Value) {
        self.title = title
        self.value = value()
    }

    var body: some View {
        PanelRow {
            Text(title)
                .layoutPriority(1)
            Spacer(minLength: 12)
            value
                .foregroundStyle(PanelStyle.secondaryText)
        }
    }
}

/// A solid button: `raised` with primary text by default, the blue accent when
/// `prominent` (one per panel at most), red text when `destructive`.
struct PanelButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false
    var compact = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 6 : 8, style: .continuous)
        configuration.label
            .font(compact ? .caption.weight(.medium) : .subheadline.weight(.medium))
            .foregroundStyle(prominent ? Color.white : (destructive ? PanelStyle.danger : PanelStyle.primaryText))
            .padding(.horizontal, compact ? 9 : 14)
            .padding(.vertical, compact ? 4 : 7)
            .background(prominent ? PanelStyle.accent : PanelStyle.raised, in: shape)
            .overlay(shape.strokeBorder(PanelStyle.hairline, lineWidth: prominent ? 0 : 0.5))
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.7 : (isEnabled ? 1 : 0.45))
    }
}
