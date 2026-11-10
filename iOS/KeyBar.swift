import SwiftUI

/// Accessory bar on top of the keyboard: the modifiers, pinned, and pages of special keys
/// and shortcuts, one of them the user's own favourites (touch and hold a key to add it).
///
/// Modifiers work like the iOS Shift key: a tap arms a modifier for the next key or
/// click only (typed letters become shortcuts when non-shift modifiers are active); a
/// double tap locks it until it is tapped again. The Mac sees an armed modifier as a
/// held key, so menus show their Option items while it is on.
struct KeyBar: View {
    /// Modifiers that apply to the next key.
    @Binding var modifiers: RDModifiers
    /// The subset of `modifiers` that stays on after a key is sent.
    @Binding var locked: RDModifiers
    /// Ids of the keys on the favourites page, in the order they were added.
    @Binding var favourites: [String]
    /// Sends a key; the second argument holds modifiers the button itself adds (e.g. ⌘ for "⌘ space").
    var onKeyTap: (RDKey, RDModifiers) -> Void

    @AppStorage("keyBarPage") private var pageRaw = KeyBarPage.keys.rawValue
    @State private var lastModifierTap: [RDModifiers: Date] = [:]
    private static let doubleTapInterval: TimeInterval = 0.4
    /// The narrow bar is showing the page names in place of the keys.
    @State private var choosingPage = false
    /// Below this width (an iPhone, an iPad's floating keyboard) the bar is laid out narrow.
    private static let wideMinWidth: CGFloat = 560

    private var page: KeyBarPage { KeyBarPage(rawValue: pageRaw) ?? .keys }

    private var pageKeys: [KeyBarKey] {
        if page == .favourites {
            return favourites.compactMap { id in KeyBarKey.all.first { $0.id == id } }
        }
        return KeyBarKey.keys(on: page)
    }

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= Self.wideMinWidth
            HStack(spacing: 6) {
                if wide {
                    // With room to spare the modifiers stay put whichever page is showing.
                    modifierButtons
                    separator
                }
                if choosingPage {
                    pageChoices
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            // On an iPhone or an iPad's floating keyboard pinned modifiers
                            // would leave room for two keys, so they lead the row instead.
                            if !wide {
                                modifierButtons
                                separator
                            }
                            if pageKeys.isEmpty {
                                Text("Touch and hold a key on another page to add it here")
                                    .font(.footnote)
                                    .foregroundStyle(SessionStyle.secondaryText)
                            }
                            ForEach(pageKeys) { key in
                                keyButton(key)
                            }
                        }
                        .padding(.trailing, 4)
                    }
                    .id(page)
                }
                if wide {
                    pagePicker
                } else {
                    pageButton
                }
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
        }
        .frame(height: Self.height)
        .foregroundStyle(.white)
        // Solid: it sits over the Mac's picture, which would show through a material.
        .background(SessionStyle.bar)
        .overlay(alignment: .top) {
            Rectangle().fill(SessionStyle.hairline).frame(height: 0.5)
        }
        .environment(\.colorScheme, .dark)
    }

    static let height: CGFloat = 50

    private var modifierButtons: some View {
        HStack(spacing: 4) {
            modifierButton("⇧", "Shift", .shift)
            modifierButton("⌃", "Control", .control)
            modifierButton("⌥", "Option", .option)
            modifierButton("⌘", "Command", .command)
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(SessionStyle.hairline)
            .frame(width: 0.5, height: 26)
    }

    /// All pages side by side, for a bar with room for them.
    private var pagePicker: some View {
        HStack(spacing: 0) {
            ForEach(KeyBarPage.allCases) { item in
                pageChip(item, compact: false)
            }
        }
        .padding(2)
        .background(SessionStyle.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// The narrow bar's page switch. It swaps the keys for the page names inside the bar:
    /// a system menu would open behind the keyboard, whose window is above the app's.
    private var pageButton: some View {
        Button {
            choosingPage.toggle()
        } label: {
            Image(systemName: choosingPage ? "xmark" : page.symbol)
                .font(.footnote.weight(.semibold))
                .frame(width: 36, height: 34)
                .background(SessionStyle.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choosingPage ? "Close key pages" : "Key page: \(page.title)")
    }

    private var pageChoices: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(KeyBarPage.allCases) { item in
                    pageChip(item, compact: true)
                }
            }
        }
    }

    private func pageChip(_ item: KeyBarPage, compact: Bool) -> some View {
        Button {
            pageRaw = item.rawValue
            choosingPage = false
        } label: {
            pageLabel(item)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 10)
                .frame(height: compact ? 34 : 30)
                .background(item == page ? SessionStyle.accent : (compact ? SessionStyle.raised : .clear),
                            in: RoundedRectangle(cornerRadius: compact ? 8 : 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(item == page ? .isSelected : [])
    }

    @ViewBuilder
    private func pageLabel(_ item: KeyBarPage) -> some View {
        if item == .favourites {
            Image(systemName: "star.fill")
        } else {
            Text(item.title)
        }
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

    private func modifierButton(_ label: String, _ name: String, _ modifier: RDModifiers) -> some View {
        let isOn = modifiers.contains(modifier)
        let isLocked = locked.contains(modifier)
        return Button {
            toggle(modifier)
        } label: {
            Text(label)
                .font(.callout.weight(.medium))
                .frame(width: 34, height: 34)
                .background(isOn ? SessionStyle.accent : SessionStyle.raised,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(isLocked ? 0.9 : 0), lineWidth: 1.5))
                .overlay(alignment: .topTrailing) {
                    if isLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 7, weight: .bold))
                            .padding(3)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityValue(isLocked ? "locked" : (isOn ? "on" : "off"))
    }

    private func keyButton(_ key: KeyBarKey) -> some View {
        let isFavourite = favourites.contains(key.id)
        return Button {
            onKeyTap(key.key, key.adding)
        } label: {
            Text(key.label)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 11)
                .frame(minWidth: 34)
                .frame(height: 34)
                .background(SessionStyle.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                if isFavourite {
                    favourites.removeAll { $0 == key.id }
                } else {
                    favourites.append(key.id)
                }
            } label: {
                Label(isFavourite ? "Remove from favourites" : "Add to favourites",
                      systemImage: isFavourite ? "star.slash" : "star")
            }
        }
    }
}

/// The key bar's pages; the modifiers are on all of them.
enum KeyBarPage: String, CaseIterable, Identifiable {
    case favourites, keys, edit, mac, function

    var id: String { rawValue }

    var title: String {
        switch self {
        case .favourites: return "Favourites"
        case .keys: return "Keys"
        case .edit: return "Edit"
        case .mac: return "Mac"
        case .function: return "F1-12"
        }
    }

    var symbol: String {
        switch self {
        case .favourites: return "star.fill"
        case .keys: return "keyboard"
        case .edit: return "scissors"
        case .mac: return "command"
        case .function: return "fn"
        }
    }
}

/// One key (or shortcut) the key bar can send.
struct KeyBarKey: Identifiable {
    /// Stable: favourites are saved by it.
    let id: String
    let label: String
    let key: RDKey
    var adding: RDModifiers = []
    let page: KeyBarPage

    static func keys(on page: KeyBarPage) -> [KeyBarKey] {
        all.filter { $0.page == page }
    }

    /// What the favourites page holds until the user changes it.
    static let defaultFavourites = ["esc", "tab", "copy", "paste", "undo", "cmd-space"]

    static let all: [KeyBarKey] = [
        KeyBarKey(id: "esc", label: "esc", key: .escape, page: .keys),
        KeyBarKey(id: "tab", label: "tab", key: .tab, page: .keys),
        KeyBarKey(id: "enter", label: "⏎", key: .returnKey, page: .keys),
        KeyBarKey(id: "shift-enter", label: "⇧ ⏎", key: .returnKey, adding: .shift, page: .keys),
        KeyBarKey(id: "delete", label: "⌫", key: .delete, page: .keys),
        KeyBarKey(id: "forward-delete", label: "⌦", key: .forwardDelete, page: .keys),
        KeyBarKey(id: "left", label: "←", key: .left, page: .keys),
        KeyBarKey(id: "up", label: "↑", key: .up, page: .keys),
        KeyBarKey(id: "down", label: "↓", key: .down, page: .keys),
        KeyBarKey(id: "right", label: "→", key: .right, page: .keys),
        KeyBarKey(id: "home", label: "home", key: .home, page: .keys),
        KeyBarKey(id: "end", label: "end", key: .end, page: .keys),
        KeyBarKey(id: "page-up", label: "pg↑", key: .pageUp, page: .keys),
        KeyBarKey(id: "page-down", label: "pg↓", key: .pageDown, page: .keys),
        KeyBarKey(id: "caps", label: "caps", key: .capsLock, page: .keys),
        KeyBarKey(id: "grave", label: "`", key: .grave, page: .keys),
        KeyBarKey(id: "tilde", label: "~", key: .grave, adding: .shift, page: .keys),

        KeyBarKey(id: "copy", label: "copy", key: .keyC, adding: .command, page: .edit),
        KeyBarKey(id: "paste", label: "paste", key: .keyV, adding: .command, page: .edit),
        KeyBarKey(id: "cut", label: "cut", key: .keyX, adding: .command, page: .edit),
        KeyBarKey(id: "undo", label: "undo", key: .keyZ, adding: .command, page: .edit),
        KeyBarKey(id: "redo", label: "redo", key: .keyZ, adding: [.command, .shift], page: .edit),
        KeyBarKey(id: "select-all", label: "select all", key: .keyA, adding: .command, page: .edit),

        KeyBarKey(id: "cmd-space", label: "⌘ space", key: .space, adding: .command, page: .mac),
        KeyBarKey(id: "cmd-tab", label: "⌘ tab", key: .tab, adding: .command, page: .mac),
        KeyBarKey(id: "cmd-w", label: "⌘ W", key: .keyW, adding: .command, page: .mac),
        KeyBarKey(id: "screenshot", label: "⌘ ⇧ 5", key: .key5, adding: [.command, .shift], page: .mac),
        // Leaves (or enters) a Mac app's full screen, where the green button is hidden.
        KeyBarKey(id: "full-screen", label: "full screen", key: .keyF, adding: [.control, .command], page: .mac),
    ] + RDKey.functionKeys.enumerated().map { index, key in
        KeyBarKey(id: "f\(index + 1)", label: "F\(index + 1)", key: key, page: .function)
    }
}
