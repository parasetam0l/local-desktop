import SwiftUI

/// A button that fires once on touch-down and then repeats while held.
///
/// The pressed state is a `@GestureState`, which SwiftUI resets even when the
/// gesture is cancelled or the view disappears mid-press, so the repeat timer
/// can't outlive the touch (or the connection).
struct RepeatingScrollButton: View {
    let iconName: String
    let action: () -> Void

    @GestureState private var isPressed = false
    @State private var timer: Timer?

    var body: some View {
        Image(systemName: iconName)
            .font(.title2)
            .frame(width: 50, height: 50)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 0.5))
            .foregroundStyle(.white)
            .opacity(isPressed ? 0.6 : 1.0)
            .shadow(radius: 4)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressed) { _, state, _ in
                        state = true
                    }
            )
            .onChange(of: isPressed) { _, pressed in
                pressed ? startRepeating() : stopRepeating()
            }
            .onDisappear {
                stopRepeating()
            }
    }

    private func startRepeating() {
        stopRepeating()
        action()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                action()
            }
        }
    }

    private func stopRepeating() {
        timer?.invalidate()
        timer = nil
    }
}
