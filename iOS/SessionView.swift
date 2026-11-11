import GameController
import SwiftUI

struct SessionView: View {
    @ObservedObject var session: ClientSession
    @ObservedObject var app: AppModel
    var onDismiss: () -> Void

    @Environment(\.scenePhase) private var scenePhase

    @State private var touchpadMode: Bool
    @State private var keyboardVisible = false
    /// The keyboard came up by itself for a text field, so it may also go away by itself.
    @State private var keyboardAutoShown = false
    /// Where the system keyboard is on screen (see `KeyboardFrameTracker`).
    @State private var keyboardFrame: CGRect?
    /// Modifiers held down on a keyboard attached to this device.
    @State private var hardwareModifiers: RDModifiers = []
    /// Modifiers armed for the next key; `lockedModifiers` stay armed afterwards.
    @State private var modifiers: RDModifiers = []
    @State private var lockedModifiers: RDModifiers = []
    /// Pointer position in remote pixels while in touchpad mode (nil until first use).
    @State private var virtualCursor: CGPoint?
    @StateObject private var canvasController = CanvasController()
    /// A short message at the top of the screen (see `SessionToast`).
    @State private var toast: Toast?

    private struct Toast: Equatable {
        let symbol: String
        let text: String
        var isFailure = false
    }

    /// The touch mode whose gestures are being introduced (the first time it is used).
    @State private var gestureCardForTouchpad: Bool?
    @AppStorage("seenTouchpadGestures") private var seenTouchpadGestures = false
    @AppStorage("seenDirectGestures") private var seenDirectGestures = false

    private func introduceGesturesIfNew() {
        guard isConnected else { return }
        if touchpadMode ? !seenTouchpadGestures : !seenDirectGestures {
            gestureCardForTouchpad = touchpadMode
        } else {
            gestureCardForTouchpad = nil
        }
    }

    private var favouriteKeys: Binding<[String]> {
        Binding(get: { app.settings.favouriteKeys ?? KeyBarKey.defaultFavourites },
                set: { app.settings.favouriteKeys = $0 })
    }

    /// Points of finger travel → points of Mac scrolling for two-finger touchpad scroll.
    private static let touchpadScrollSpeed = 1.5

    init(session: ClientSession, app: AppModel, onDismiss: @escaping () -> Void = {}) {
        self.session = session
        self.app = app
        self.onDismiss = onDismiss
        _touchpadMode = State(initialValue: app.settings.defaultTouchpad)
    }

    private var isConnected: Bool { session.phase == .connected }
    /// Only while the key bar shows them can they be seen and turned off, so a hidden
    /// keyboard or a backgrounded app never leaves a key stuck down on the Mac.
    private var modifiersToHold: RDModifiers {
        isConnected && keyboardVisible && scenePhase == .active ? modifiers.union(hardwareModifiers) : []
    }

    /// Room the key bar takes above a docked keyboard (an iPhone's, or a docked iPad
    /// keyboard); a floating keyboard carries the key bar with it, away from the bottom edge.
    private var dockedKeyBarInset: CGFloat {
        isConnected && keyboardVisible && (keyboardFrame.map { $0.minX <= 1 && $0.height > 0 } ?? false)
            ? KeyBar.height : 0
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // The room the Mac's picture has: the screen without its safe areas, whether
            // the keyboard is up or not. A desktop size that fills the device is made
            // from it, and follows it when the device is turned.
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size, initial: true) { _, size in
                        session.pictureArea = size
                    }
            }
            .ignoresSafeArea(.keyboard)
            .allowsHitTesting(false)

            // Kept alive across reconnects so the last frame and PiP survive a drop.
            if session.hasConnectedOnce {
                ZoomableCanvas(
                    session: session,
                    contentSize: session.remoteSize,
                    controller: canvasController,
                    onTap: directTapHandler,
                    onRightTap: directRightTapHandler,
                    onDrag: dragHandler,
                    onScroll: directScrollHandler,
                    isZoomLocked: app.settings.isZoomLocked,
                    isOneFingerScroll: app.settings.isOneFingerScroll
                )
                .allowsHitTesting(isConnected && (!touchpadMode || session.isViewOnly))
                // The picture ends above the key bar rather than behind it.
                .padding(.bottom, dockedKeyBarInset)
            }

            if touchpadMode, isConnected, !session.isViewOnly {
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
                            _ = consumeModifiers()
                        }
                    }
                )

                if app.settings.showScrollHelpers {
                    VStack(spacing: 8) {
                        RepeatingScrollButton(iconName: "chevron.up") {
                            session.scroll(dx: 0, dy: 1)
                        }
                        RepeatingScrollButton(iconName: "chevron.down") {
                            session.scroll(dx: 0, dy: -1)
                        }
                    }
                    .padding(.trailing, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                }
            }

            SessionStateOverlay(session: session, app: app, onDismiss: onDismiss)
                .zIndex(isConnected ? 0 : 100)

            if isConnected {
                KeyboardFrameTracker { keyboardFrame = $0 }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                // Sits on top of the keyboard wherever it is (docked, or floating on an
                // iPad) and over the Mac's picture, so it never takes room from it.
                if keyboardVisible, let frame = keyboardFrame {
                    KeyBar(modifiers: $modifiers, locked: $lockedModifiers, favourites: favouriteKeys,
                           capsLockOn: session.macCapsLock) { key, extra in
                        session.keyTap(key, modifiers: consumeModifiers().union(extra))
                    } onHideKeyboard: {
                        keyboardAutoShown = false
                        keyboardVisible = false
                    }
                    .frame(width: frame.width)
                    .clipShape(RoundedRectangle(cornerRadius: frame.minX > 1 ? 12 : 0))
                    .alignmentGuide(.top) { $0[.bottom] }
                    .offset(x: frame.minX, y: frame.minY)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .ignoresSafeArea()
                    .zIndex(50)
                }

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
                    onHardwareKey: { code, down in
                        // The key bar's armed modifiers apply to the key and are used up by it.
                        let armed = down ? consumeModifiers() : []
                        session.hardwareKey(code: code, down: down, modifiers: armed.union(hardwareModifiers))
                    },
                    onHardwareModifiers: { hardwareModifiers = $0 },
                    onDismissed: {
                        keyboardAutoShown = false
                        hardwareModifiers = []
                        keyboardVisible = false
                    }
                )
                .allowsHitTesting(false)
                .frame(width: 1, height: 1)

                SessionControlBar(
                    touchpadMode: $touchpadMode,
                    keyboardVisible: $keyboardVisible,
                    app: app,
                    session: session,
                    canvasController: canvasController,
                    // Keeps clear of the key bar, which is drawn on top of the keyboard.
                    bottomInset: dockedKeyBarInset > 0 ? dockedKeyBarInset + 4 : 0,
                    onKeyboardToggle: {
                        keyboardAutoShown = false
                        keyboardVisible.toggle()
                    },
                    onDisconnect: onDismiss
                )
                .zIndex(40)

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
                    if let toast {
                        SessionToast(symbol: toast.symbol, text: toast.text, isFailure: toast.isFailure)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.top, 16)
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
                .animation(.snappy(duration: 0.25), value: toast)
                .task(id: toast) {
                    guard toast != nil else { return }
                    // A failure stays long enough to be read.
                    try? await Task.sleep(nanoseconds: toast?.isFailure == true ? 5_000_000_000 : 2_000_000_000)
                    if !Task.isCancelled { toast = nil }
                }

                if let forTouchpad = gestureCardForTouchpad {
                    GestureCard(touchpad: forTouchpad,
                                hints: GestureHint.hints(touchpad: forTouchpad,
                                                         oneFingerScroll: app.settings.isOneFingerScroll,
                                                         zoomLocked: app.settings.isZoomLocked)) {
                        if forTouchpad { seenTouchpadGestures = true } else { seenDirectGestures = true }
                        withAnimation(.snappy(duration: 0.25)) { gestureCardForTouchpad = nil }
                    }
                    .transition(.opacity)
                    .zIndex(60)
                }
            }
        }
        .onAppear {
            // With a keyboard attached there is no on-screen keyboard to cover the
            // picture, so its keys go to the Mac from the start.
            if GCKeyboard.coalesced != nil { keyboardVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in
            if isConnected { keyboardVisible = true }
        }
        .onChange(of: session.notice) { _, notice in
            if let notice {
                toast = Toast(symbol: notice.symbol, text: notice.text, isFailure: notice.isFailure)
            }
        }
        .onChange(of: isConnected, initial: true) {
            introduceGesturesIfNew()
        }
        .onChange(of: modifiersToHold) { _, held in
            session.setHeldModifiers(held)
        }
        .onChange(of: session.textFocusReport.count) {
            // A tap landed in a text field on the Mac: bring the keyboard up. It goes away
            // again by itself only if it also came up by itself.
            if session.textFocusReport.editable {
                // Direct mode only: in touchpad mode a tap is a click wherever the pointer
                // happens to be, and the keyboard coming up for it gets in the way.
                if !keyboardVisible, !touchpadMode {
                    keyboardVisible = true
                    keyboardAutoShown = true
                }
            } else if keyboardAutoShown, keyboardVisible {
                keyboardVisible = false
                keyboardAutoShown = false
            }
        }
        .onChange(of: touchpadMode) { _, isTrackpad in
            toast = isTrackpad
                ? Toast(symbol: "rectangle.and.hand.point.up.left", text: "Touchpad mode")
                : Toast(symbol: "hand.tap", text: "Direct touch mode")
            introduceGesturesIfNew()
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

    /// Returns the modifiers for the key or click being sent and disarms the one-shot ones.
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
        _ = consumeModifiers()
    }

    // MARK: Direct mode

    private var directTapHandler: ((CGPoint) -> Void)? {
        isConnected && !touchpadMode ? { point in
            if session.isDisplaySleeping {
                session.wakeHostDisplay()
            }
            session.click(button: 0, atRemote: point)
            _ = consumeModifiers()
        } : nil
    }

    private var directRightTapHandler: ((CGPoint) -> Void)? {
        isConnected && !touchpadMode ? { point in
            if session.isDisplaySleeping {
                session.wakeHostDisplay()
            }
            session.click(button: 1, atRemote: point)
            _ = consumeModifiers()
        } : nil
    }

    /// Two-finger drag in direct mode: point the Mac's cursor at the fingers, then scroll
    /// like the touchpad's two-finger scroll.
    private var directScrollHandler: ((CGPoint?, CGFloat, CGFloat) -> Void)? {
        isConnected && !touchpadMode ? { start, dx, dy in
            if let start {
                if session.isDisplaySleeping {
                    session.wakeHostDisplay()
                }
                session.moveAbs(Double(start.x), Double(start.y))
            }
            session.scroll(dx: Double(dx) * Self.touchpadScrollSpeed,
                           dy: Double(dy) * Self.touchpadScrollSpeed,
                           precise: true)
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
            _ = consumeModifiers()
        }
    }
}
