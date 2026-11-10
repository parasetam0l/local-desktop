import SwiftUI

/// What each touch gesture does on the Mac, per touch mode.
struct GestureHint: Identifiable {
    let symbol: String
    let gesture: String
    let result: String
    var id: String { gesture }

    static func hints(touchpad: Bool, oneFingerScroll: Bool, zoomLocked: Bool) -> [GestureHint] {
        var hints: [GestureHint]
        if touchpad {
            hints = [
                GestureHint(symbol: "hand.point.up.left", gesture: "Drag", result: "Move the pointer"),
                GestureHint(symbol: "hand.tap", gesture: "Tap", result: "Click where the pointer is"),
                GestureHint(symbol: "hand.tap", gesture: "Two-finger tap, or touch and hold", result: "Right click"),
                GestureHint(symbol: "hand.draw", gesture: "Tap, then touch again and drag", result: "Drag with the mouse button down"),
                GestureHint(symbol: "arrow.up.and.down", gesture: "Two-finger drag", result: "Scroll"),
            ]
        } else if oneFingerScroll {
            hints = [
                GestureHint(symbol: "hand.tap", gesture: "Tap", result: "Click right there"),
                GestureHint(symbol: "hand.tap", gesture: "Two-finger tap", result: "Right click"),
                GestureHint(symbol: "arrow.up.and.down", gesture: "Drag", result: "Scroll"),
                GestureHint(symbol: "hand.draw", gesture: "Touch and hold, then drag", result: "Drag with the mouse button down"),
            ]
        } else {
            hints = [
                GestureHint(symbol: "hand.tap", gesture: "Tap", result: "Click right there"),
                GestureHint(symbol: "hand.tap", gesture: "Two-finger tap, or touch and hold", result: "Right click"),
                GestureHint(symbol: "hand.draw", gesture: "Drag", result: "Drag with the mouse button down"),
                GestureHint(symbol: "arrow.up.and.down", gesture: "Two-finger drag", result: "Scroll"),
            ]
        }
        if !zoomLocked {
            hints.append(GestureHint(symbol: "arrow.up.left.and.arrow.down.right", gesture: "Pinch", result: "Zoom the picture"))
        }
        return hints
    }
}

struct GestureHintRows: View {
    let hints: [GestureHint]

    var body: some View {
        ForEach(hints) { hint in
            PanelRow {
                Image(systemName: hint.symbol)
                    .foregroundStyle(SessionStyle.accent)
                    .frame(width: 24)
                Text(hint.gesture)
                Spacer(minLength: 12)
                Text(hint.result)
                    .foregroundStyle(SessionStyle.secondaryText)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

/// The full guide: both touch modes, opened from the session panel and from Settings.
struct GestureGuideView: View {
    @ObservedObject var app: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Gestures")
                    .font(.headline)
                Spacer()
                Button("Done") { isPresented = false }
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PanelSection("Direct touch", footer: app.settings.isOneFingerScroll
                                 ? "One-finger scroll is on, so a drag scrolls." : nil) {
                        GestureHintRows(hints: GestureHint.hints(touchpad: false,
                                                                 oneFingerScroll: app.settings.isOneFingerScroll,
                                                                 zoomLocked: app.settings.isZoomLocked))
                    }
                    PanelSection("Touchpad") {
                        GestureHintRows(hints: GestureHint.hints(touchpad: true, oneFingerScroll: false,
                                                                 zoomLocked: app.settings.isZoomLocked))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
        .sessionPage()
    }
}

/// Shown over the session the first time a touch mode is used.
struct GestureCard: View {
    let touchpad: Bool
    let hints: [GestureHint]
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(touchpad ? "Touchpad mode" : "Direct touch mode")
                .font(.headline)
                .padding(.horizontal, 14)
            VStack(spacing: 0) {
                GestureHintRows(hints: hints)
            }
            Button("Got it", action: onDone)
                .buttonStyle(SessionButtonStyle(prominent: true, fullWidth: true))
                .padding(.horizontal, 14)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: 380)
        .foregroundStyle(.white)
        .sessionSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
    }
}
