import SwiftUI

/// The Mac's front window, by name, with the actions for it: close, minimise, full
/// screen, and placing it on a half or the whole of its screen. Opened from the control bar.
struct WindowControlsView: View {
    @ObservedObject var session: ClientSession
    @Binding var isPresented: Bool

    private var window: RDFrontWindowMsg? { session.frontWindow }
    private var hasWindow: Bool { window?.title != nil }
    private var isFullScreen: Bool { window?.isFullScreen ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(heading)
                        .font(.headline)
                        .lineLimit(2)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(SessionStyle.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button {
                    session.requestFrontWindow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(SessionButtonStyle(compact: true))
                .accessibilityLabel("Refresh")
            }

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    action("xmark", "Close", .windowClose)
                    action("minus", "Minimise", .windowMinimize)
                    action(isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                           isFullScreen ? "Exit full screen" : "Full screen", .windowFullScreen)
                }
                Rectangle().fill(SessionStyle.hairline).frame(height: 0.5)
                HStack(spacing: 0) {
                    action("rectangle.lefthalf.inset.filled", "Left half", .windowLeftHalf, needsFrame: true)
                    action("rectangle.righthalf.inset.filled", "Right half", .windowRightHalf, needsFrame: true)
                    action("rectangle.inset.filled", "Fill", .windowFill, needsFrame: true)
                }
            }
            .sessionCard()
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .sessionPage()
        .presentationDetents([.height(250)])
        .presentationDragIndicator(.visible)
    }

    private var heading: String {
        guard let window else { return "Looking for the front window" }
        guard let title = window.title else { return "No window in front" }
        return title.isEmpty ? window.app : title
    }

    private var detail: String {
        guard let window else { return " " }
        if window.title == nil { return window.app }
        return window.title?.isEmpty == true ? "Front window" : window.app
    }

    /// `needsFrame`: placing a window isn't possible while it is full screen.
    private func action(_ symbol: String, _ title: String, _ type: RDSystemActionType,
                        needsFrame: Bool = false) -> some View {
        let enabled = hasWindow && !(needsFrame && isFullScreen)
        return Button {
            session.triggerSystemAction(type)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .frame(height: 22)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(SessionStyle.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.35)
        .disabled(!enabled)
        .accessibilityLabel("\(title), the Mac's front window")
    }
}
