import SwiftUI

/// Accessory bar above the session controls: sticky modifiers plus common
/// special keys. Modifier state applies to the next key event (including
/// typed letters, which are converted to shortcuts when non-shift modifiers
/// are active).
struct KeyBar: View {
    @Binding var modifiers: RDModifiers
    var onKeyTap: (RDKey, RDModifiers) -> Void

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
                Button {
                    modifiers.insert(.shift)
                    onKeyTap(.returnKey, modifiers)
                } label: {
                    Text("⇧ enter")
                        .font(.footnote)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                
                Button {
                    var mods = modifiers
                    mods.insert(.command)
                    onKeyTap(.space, mods)
                } label: {
                    Text("⌘ space")
                        .font(.footnote)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
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

    private func modifierButton(_ label: String, _ modifier: RDModifiers) -> some View {
        Button {
            if modifiers.contains(modifier) {
                modifiers.remove(modifier)
            } else {
                modifiers.insert(modifier)
            }
        } label: {
            Text(label)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(modifiers.contains(modifier) ? Color.white : Color.primary)
                .background(modifiers.contains(modifier) ? Color.accentColor : Color.primary.opacity(0.08),
                            in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func keyButton(_ label: String, _ key: RDKey) -> some View {
        Button {
            onKeyTap(key, modifiers)
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
