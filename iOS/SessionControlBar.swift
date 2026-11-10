import SwiftUI

/// The session's floating controls: one bar with the frequent actions, which shrinks to
/// a small handle when it hasn't been used for a few seconds so it covers almost none
/// of the Mac's picture. It can be dragged to any edge of the screen and stays there.
struct SessionControlBar: View {
    @Binding var touchpadMode: Bool
    @Binding var keyboardVisible: Bool
    @ObservedObject var app: AppModel
    @ObservedObject var session: ClientSession
    @ObservedObject var canvasController: CanvasController
    /// Room to keep free at the bottom (the key bar, while the keyboard is up).
    var bottomInset: CGFloat = 0
    var onKeyboardToggle: () -> Void
    var onDisconnect: () -> Void

    private enum Edge: String { case top, bottom, leading, trailing }

    @AppStorage("sessionBarEdge") private var edgeRaw = Edge.bottom.rawValue
    @AppStorage("sessionBarFraction") private var fraction = 0.5
    @State private var collapsed = false
    /// Changes with every use of the bar, which restarts the idle countdown.
    @State private var activity = 0
    @State private var dragTranslation: CGSize?
    @State private var showApps = false
    @State private var showPanel = false
    @State private var confirmDisconnect = false

    private static let idleSeconds: UInt64 = 5
    private static let buttonSize = CGSize(width: 44, height: 40)
    private static let barPadding: CGFloat = 5
    private static let barSpacing: CGFloat = 2
    private static let buttonCount: CGFloat = 5
    private static let handleLength: CGFloat = 44
    private static let handleThickness: CGFloat = 22
    private static let margin: CGFloat = 8

    private var edge: Edge { Edge(rawValue: edgeRaw) ?? .bottom }
    private var isVertical: Bool { edge == .leading || edge == .trailing }
    private var isPresenting: Bool { showApps || showPanel || confirmDisconnect }

    var body: some View {
        GeometryReader { proxy in
            let size = barSize
            bar
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .highPriorityGesture(dragGesture(in: proxy.size))
                .position(position(in: proxy.size, barSize: size))
                .animation(.snappy(duration: 0.25), value: collapsed)
                .animation(.snappy(duration: 0.25), value: edgeRaw)
                .animation(.snappy(duration: 0.25), value: bottomInset)
        }
        .task(id: IdleKey(activity: activity, paused: isPresenting || dragTranslation != nil)) {
            guard !isPresenting, dragTranslation == nil else { return }
            try? await Task.sleep(nanoseconds: Self.idleSeconds * 1_000_000_000)
            if !Task.isCancelled { collapsed = true }
        }
    }

    private struct IdleKey: Equatable {
        let activity: Int
        let paused: Bool
    }

    // MARK: Layout

    private var barSize: CGSize {
        let length: CGFloat
        let thickness: CGFloat
        if collapsed {
            length = Self.handleLength
            thickness = Self.handleThickness
        } else {
            let along = isVertical ? Self.buttonSize.height : Self.buttonSize.width
            let across = isVertical ? Self.buttonSize.width : Self.buttonSize.height
            length = along * Self.buttonCount + Self.barSpacing * (Self.buttonCount - 1) + Self.barPadding * 2
            thickness = across + Self.barPadding * 2
        }
        return isVertical ? CGSize(width: thickness, height: length) : CGSize(width: length, height: thickness)
    }

    private func position(in container: CGSize, barSize: CGSize) -> CGPoint {
        var point = restingPosition(in: container, barSize: barSize)
        if let dragTranslation {
            point.x += dragTranslation.width
            point.y += dragTranslation.height
        }
        return point
    }

    private func restingPosition(in container: CGSize, barSize: CGSize) -> CGPoint {
        let halfWidth = barSize.width / 2
        let halfHeight = barSize.height / 2
        let minX = Self.margin + halfWidth
        let maxX = max(minX, container.width - Self.margin - halfWidth)
        let minY = Self.margin + halfHeight
        let maxY = max(minY, container.height - Self.margin - halfHeight - bottomInset)
        let alongX = min(max(container.width * fraction, minX), maxX)
        let alongY = min(max(container.height * fraction, minY), maxY)
        switch edge {
        case .bottom: return CGPoint(x: alongX, y: maxY)
        case .top: return CGPoint(x: alongX, y: minY)
        case .leading: return CGPoint(x: minX, y: alongY)
        case .trailing: return CGPoint(x: maxX, y: alongY)
        }
    }

    private func dragGesture(in container: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { dragTranslation = $0.translation }
            .onEnded { value in
                var drop = restingPosition(in: container, barSize: barSize)
                drop.x += value.translation.width
                drop.y += value.translation.height
                dragTranslation = nil
                guard container.width > 0, container.height > 0 else { return }
                // Snap to whichever edge the bar was dropped closest to.
                let distances: [(Edge, CGFloat)] = [
                    (.leading, drop.x), (.trailing, container.width - drop.x),
                    (.top, drop.y), (.bottom, container.height - drop.y),
                ]
                let nearest = distances.min { $0.1 < $1.1 }?.0 ?? .bottom
                let along = nearest == .top || nearest == .bottom
                    ? drop.x / container.width : drop.y / container.height
                fraction = min(max(along, 0), 1)
                edgeRaw = nearest.rawValue
                activity += 1
            }
    }

    // MARK: Content

    @ViewBuilder
    private var bar: some View {
        let layout = isVertical
            ? AnyLayout(VStackLayout(spacing: Self.barSpacing))
            : AnyLayout(HStackLayout(spacing: Self.barSpacing))
        ZStack {
            // The buttons stay in the hierarchy while collapsed, so a popover they
            // opened keeps its anchor.
            layout {
                barButton(keyboardVisible ? "keyboard.fill" : "keyboard", "Keyboard",
                          isOn: keyboardVisible) {
                    onKeyboardToggle()
                }
                barButton("square.stack.3d.up", "Mac apps") {
                    showApps = true
                }
                .adaptiveSheet(isPresented: $showApps, padSize: CGSize(width: 440, height: 560)) {
                    AppSwitcherView(session: session, isPresented: $showApps)
                }
                barButton(touchpadMode ? "rectangle.and.hand.point.up.left" : "hand.tap",
                          touchpadMode ? "Touchpad mode" : "Direct touch mode") {
                    touchpadMode.toggle()
                }
                .accessibilityHint("Switches between touchpad and direct touch")
                barButton("slider.horizontal.3", "Session settings") {
                    showPanel = true
                }
                .adaptiveSheet(isPresented: $showPanel, padSize: CGSize(width: 380, height: 600)) {
                    SessionPanel(touchpadMode: $touchpadMode, app: app, session: session,
                                 canvasController: canvasController, isPresented: $showPanel,
                                 onDisconnect: onDisconnect)
                }
                barButton("xmark", "Disconnect", tint: SessionStyle.danger) {
                    confirmDisconnect = true
                }
                .confirmationDialog("Disconnect from \(session.serverName.isEmpty ? "the Mac" : session.serverName)?",
                                    isPresented: $confirmDisconnect, titleVisibility: .visible) {
                    Button("Disconnect", role: .destructive, action: onDisconnect)
                }
            }
            .padding(Self.barPadding)
            .sessionSurface(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .fixedSize()
            .opacity(collapsed ? 0 : 1)
            .allowsHitTesting(!collapsed)
            .accessibilityHidden(collapsed)

            if collapsed {
                Button {
                    collapsed = false
                    activity += 1
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.footnote.weight(.bold))
                        .rotationEffect(isVertical ? .degrees(90) : .zero)
                        .foregroundStyle(.white)
                        .frame(width: isVertical ? Self.handleThickness : Self.handleLength,
                               height: isVertical ? Self.handleLength : Self.handleThickness)
                        .sessionSurface(Capsule())
                        .opacity(0.7)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show session controls")
                .transition(.opacity)
            }
        }
    }

    private func barButton(_ symbol: String, _ label: String, isOn: Bool = false,
                           tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button {
            activity += 1
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isOn ? .white : tint)
                .frame(width: Self.buttonSize.width, height: Self.buttonSize.height)
                .background(isOn ? SessionStyle.accent : .clear,
                            in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
