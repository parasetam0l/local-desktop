import SwiftUI

/// Accessory bar above the session controls: modifiers plus common special keys.
///
/// Modifiers work like the iOS Shift key: a tap arms a modifier for the next key
/// only (including typed letters, which become shortcuts when non-shift modifiers
/// are active); a double tap locks it until it is tapped again.
struct KeyBar: View {
    /// Modifiers that apply to the next key.
    @Binding var modifiers: RDModifiers
    /// The subset of `modifiers` that stays on after a key is sent.
    @Binding var locked: RDModifiers
    /// Sends a key; the second argument holds modifiers the button itself adds (e.g. ⌘ for "⌘ space").
    var onKeyTap: (RDKey, RDModifiers) -> Void

    @State private var lastModifierTap: [RDModifiers: Date] = [:]
    private static let doubleTapInterval: TimeInterval = 0.4

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                modifierButton("shift", .shift)
                modifierButton("ctrl", .control)
                modifierButton("alt", .option)
                modifierButton("cmd", .command)
                Divider()
                    .frame(height: 22)
                keyButton("esc", .escape)
                keyButton("tab", .tab)
                keyButton("enter", .returnKey)
                keyButton("⇧ enter", .returnKey, adding: .shift)
                keyButton("⌘ space", .space, adding: .command)
                keyButton("⌘ ⇧ 5", .key5, adding: [.command, .shift])
                keyButton("⌫", .delete)
                keyButton("←", .left)
                keyButton("↑", .up)
                keyButton("↓", .down)
                keyButton("→", .right)
                keyButton("home", .home)
                keyButton("end", .end)
                keyButton("pg↑", .pageUp)
                keyButton("pg↓", .pageDown)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
    }

    private func toggle(_ modifier: RDModifiers) {
        let now = Date()
        defer { lastModifierTap[modifier] = now }
        if locked.contains(modifier) {
            locked.remove(modifier)
            modifiers.remove(modifier)
        } else if modifiers.contains(modifier) {
            if let last = lastModifierTap[modifier], now.timeIntervalSince(last) < Self.doubleTapInterval {
                locked.insert(modifier)
            } else {
                modifiers.remove(modifier)
            }
        } else {
            modifiers.insert(modifier)
        }
    }

    private func modifierButton(_ label: String, _ modifier: RDModifiers) -> some View {
        let isOn = modifiers.contains(modifier)
        let isLocked = locked.contains(modifier)
        return Button {
            toggle(modifier)
        } label: {
            HStack(spacing: 3) {
                Text(label)
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                }
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .background(isOn ? Color.accentColor : Color.primary.opacity(0.08), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(isLocked ? 0.9 : 0), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityValue(isLocked ? "locked" : (isOn ? "on" : "off"))
    }

    private func keyButton(_ label: String, _ key: RDKey, adding extra: RDModifiers = []) -> some View {
        Button {
            onKeyTap(key, extra)
        } label: {
            Text(label)
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
