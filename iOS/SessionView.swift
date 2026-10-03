import SwiftUI

struct SessionView: View {
    @ObservedObject var session: ClientSession
    @ObservedObject var app: AppModel
    var onDismiss: () -> Void

    @State private var touchpadMode: Bool
    @State private var keyboardVisible = false
    /// Modifiers armed for the next key; `lockedModifiers` stay armed afterwards.
    @State private var modifiers: RDModifiers = []
    @State private var lockedModifiers: RDModifiers = []
    /// Pointer position in remote pixels while in touchpad mode (nil until first use).
    @State private var virtualCursor: CGPoint?
    @StateObject private var canvasController = CanvasController()

    /// Points of finger travel → points of Mac scrolling for two-finger touchpad scroll.
    private static let touchpadScrollSpeed = 1.5

    init(session: ClientSession, app: AppModel, onDismiss: @escaping () -> Void = {}) {
        self.session = session
        self.app = app
        self.onDismiss = onDismiss
        _touchpadMode = State(initialValue: app.settings.defaultTouchpad)
    }

    private var isConnected: Bool { session.phase == .connected }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Kept alive across reconnects so the last frame and PiP survive a drop.
            if session.hasConnectedOnce {
                ZoomableCanvas(
                    session: session,
                    contentSize: session.remoteSize,
                    controller: canvasController,
                    onTap: directTapHandler,
                    onRightTap: directRightTapHandler,
                    onDrag: dragHandler
                )
                .allowsHitTesting(isConnected && !touchpadMode)
            }

            if touchpadMode, isConnected {
                TouchpadOverlay(
                    controller: canvasController,
                    onMove: moveVirtualCursor,
                    onLeftClick: { click(button: 0) },
                    onRightClick: { click(button: 1) },
                    onScroll: { dx, dy in
                        session.scroll(dx: Double(dx) * Self.touchpadScrollSpeed,
                                       dy: Double(dy) * Self.touchpadScrollSpeed,
                                       precise: true)
                    },
                    onDragStateChange: { isDown in
                        if isDown {
                            session.buttonDown(0)
                        } else {
                            session.buttonUp(0)
                        }
                    }
                )

                if app.settings.showScrollHelpers {
                    VStack(spacing: 16) {
                        RepeatingScrollButton(iconName: "chevron.up") {
                            session.scroll(dx: 0, dy: 1)
                        }
                        RepeatingScrollButton(iconName: "chevron.down") {
                            session.scroll(dx: 0, dy: -1)
                        }
                    }
                    .padding(.trailing, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                }
            }

            SessionStateOverlay(session: session, app: app, onDismiss: onDismiss)
                .zIndex(isConnected ? 0 : 100)

            if isConnected {
                KeyboardCapture(
                    isActive: keyboardVisible,
                    onText: { text in
                        session.typeText(text, modifiers: consumeModifiers())
                    },
                    onDelete: {
                        session.keyTap(.delete, modifiers: consumeModifiers())
                    },
                    onReturnKey: {
                        session.keyTap(.returnKey, modifiers: consumeModifiers())
                    },
                    onArrowKey: { key in
                        session.keyTap(key, modifiers: consumeModifiers())
                    },
                    onDismissed: {
                        keyboardVisible = false
                    }
                )
                .allowsHitTesting(false)
                .frame(width: 1, height: 1)

                HStack(spacing: 14) {
                    SessionMenuButton(
                        touchpadMode: $touchpadMode,
                        app: app,
                        session: session,
                        canvasController: canvasController,
                        onDismiss: onDismiss
                    )

                    AppSwitcherButton(session: session)

                    Spacer()

                    Button {
                        keyboardVisible.toggle()
                    } label: {
                        Image(systemName: keyboardVisible ? "keyboard.fill" : "keyboard")
                            .font(.title2)
                            .frame(width: 50, height: 50)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 0.5))
                            .foregroundStyle(.white)
                            .shadow(radius: 4)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .frame(maxHeight: .infinity, alignment: .bottom)

                // Top Overlays: Debug HUD & Mac Locked Banner
                VStack(spacing: 8) {
                    if session.showDebugHUD {
                        DebugHUDView(session: session)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if session.isHostLocked {
                        HostLockedBanner()
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.top, 16)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isConnected && keyboardVisible {
                KeyBar(modifiers: $modifiers, locked: $lockedModifiers) { key, extra in
                    session.keyTap(key, modifiers: consumeModifiers().union(extra))
                }
                .background(.ultraThinMaterial)
            }
        }
        .onChange(of: touchpadMode) { _, isTrackpad in
            if isTrackpad {
                if !app.settings.showRemoteCursor, let cursor = currentVirtualCursor() {
                    canvasController.canvas?.showCursor(at: cursor)
                }
            } else {
                canvasController.canvas?.hideCursor()
            }
        }
        .onChange(of: app.settings.showRemoteCursor) { _, showRemote in
            if showRemote || !touchpadMode {
                canvasController.canvas?.hideCursor()
            } else if let virtualCursor {
                canvasController.canvas?.showCursor(at: virtualCursor)
            }
        }
    }

    /// Returns the modifiers for the key being sent and disarms the one-shot ones.
    private func consumeModifiers() -> RDModifiers {
        let current = modifiers
        modifiers = modifiers.intersection(lockedModifiers)
        return current
    }

    // MARK: Touchpad

    /// The virtual cursor, starting at the screen center once the stream size is known.
    private func currentVirtualCursor() -> CGPoint? {
        if let virtualCursor {
            return virtualCursor
        }
        let size = session.remoteSize
        guard size.width > 0, size.height > 0 else { return nil }
        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        virtualCursor = center
        return center
    }

    private func moveVirtualCursor(dx: CGFloat, dy: CGFloat) {
        let speed = app.settings.pointerSpeedMultiplier
        let scaledDx = dx * speed
        let scaledDy = dy * speed
        let size = session.remoteSize
        guard var cursor = currentVirtualCursor() else {
            session.moveRel(dx: scaledDx, dy: scaledDy)
            return
        }
        cursor.x = min(max(0, cursor.x + scaledDx), size.width)
        cursor.y = min(max(0, cursor.y + scaledDy), size.height)
        virtualCursor = cursor
        if !app.settings.showRemoteCursor {
            canvasController.canvas?.showCursor(at: cursor)
        }
        canvasController.canvas?.centerOn(remotePoint: cursor)
        session.moveAbs(Double(cursor.x), Double(cursor.y))
    }

    private func click(button: Int) {
        if session.isDisplaySleeping {
            session.wakeHostDisplay()
        }
        session.click(button: button, atRemote: virtualCursor)
    }

    // MARK: Direct mode

    private var directTapHandler: ((CGPoint) -> Void)? {
        isConnected && !touchpadMode ? { point in
            if session.isDisplaySleeping {
                session.wakeHostDisplay()
            }
            session.click(button: 0, atRemote: point)
        } : nil
    }

    private var directRightTapHandler: ((CGPoint) -> Void)? {
        isConnected && !touchpadMode ? { point in
            if session.isDisplaySleeping {
                session.wakeHostDisplay()
            }
            session.click(button: 1, atRemote: point)
        } : nil
    }

    private var dragHandler: ((DragEvent) -> Void)? {
        guard isConnected else { return nil }
        return { event in handleDragEvent(event) }
    }

    private func handleDragEvent(_ event: DragEvent) {
        if session.isDisplaySleeping {
            session.wakeHostDisplay()
        }
        switch event {
        case .began(let point):
            session.moveAbs(Double(point.x), Double(point.y))
            session.buttonDown(0)
        case .changed(let point):
            session.moveAbs(Double(point.x), Double(point.y))
        case .ended:
            session.buttonUp(0)
        }
    }
}
