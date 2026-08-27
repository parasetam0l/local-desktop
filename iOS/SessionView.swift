import SwiftUI

struct RepeatingScrollButton: View {
    let iconName: String
    let action: () -> Void
    
    @State private var timer: Timer?
    @State private var isPressed = false

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
                    .onChanged { _ in
                        if timer == nil {
                            isPressed = true
                            action()
                            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                                action()
                            }
                        }
                    }
                    .onEnded { _ in
                        isPressed = false
                        timer?.invalidate()
                        timer = nil
                    }
            )
    }
}

struct SessionView: View {
    @ObservedObject var session: ClientSession
    @ObservedObject var app: AppModel
    var onDismiss: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var touchpadMode: Bool
    @State private var keyboardVisible = false
    @State private var modifiers: RDModifiers = []
    @StateObject private var canvasController = CanvasController()

    init(session: ClientSession, app: AppModel, onDismiss: @escaping () -> Void = {}) {
        self.session = session
        self.app = app
        self.onDismiss = onDismiss
        _touchpadMode = State(initialValue: app.settings.defaultTouchpad)
    }

    @State private var virtualCursor: CGPoint = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if session.phase == .connected {
                ZoomableCanvas(
                    image: session.image,
                    controller: canvasController,
                    onTap: directTapHandler,
                    onRightTap: directRightTapHandler,
                    onDrag: dragHandler
                )
                .allowsHitTesting(!touchpadMode)
            }

            if touchpadMode, session.phase == .connected {
                TouchpadOverlay(
                    controller: canvasController,
                    onMove: { dx, dy in
                        let speed = app.settings.pointerSpeedMultiplier
                        let scaledDx = dx * speed
                        let scaledDy = dy * speed
                        let size = session.remoteSize
                        if size.width > 0, size.height > 0 {
                            if virtualCursor == .zero {
                                virtualCursor = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
                            }
                            virtualCursor.x = min(max(0, virtualCursor.x + scaledDx), size.width)
                            virtualCursor.y = min(max(0, virtualCursor.y + scaledDy), size.height)
                            if !app.settings.showRemoteCursor {
                                canvasController.canvas?.showCursor(at: virtualCursor)
                            }
                            canvasController.canvas?.centerOn(remotePoint: virtualCursor)
                            session.moveAbs(Double(virtualCursor.x), Double(virtualCursor.y))
                        } else {
                            session.moveRel(dx: scaledDx, dy: scaledDy)
                        }
                    },
                    onLeftClick: { point in
                        session.click(button: 0, atRemote: point ?? (virtualCursor != .zero ? virtualCursor : nil))
                    },
                    onRightClick: { point in
                        session.click(button: 1, atRemote: point ?? (virtualCursor != .zero ? virtualCursor : nil))
                    },
                    onScroll: { dx, dy in
                        session.scroll(dx: dx, dy: dy)
                    },
                    onDrag: dragHandler ?? { _ in }
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

            if session.phase != .connected {
                stateOverlay
                    .zIndex(100)
            } else {
                stateOverlay
            }

            if session.phase == .connected {
                KeyboardCapture(
                    isActive: keyboardVisible,
                    onText: { text in
                        session.typeText(text, modifiers: modifiers)
                    },
                    onDelete: {
                        session.keyTap(.delete, modifiers: modifiers)
                    },
                    onReturnKey: {
                        session.keyTap(.returnKey, modifiers: modifiers)
                    }
                )
                .allowsHitTesting(false)
                .frame(width: 1, height: 1)

                HStack {
                    Menu {
                        Button {
                            touchpadMode.toggle()
                        } label: {
                            Label(touchpadMode ? "Direct Mode" : "Touchpad Mode", systemImage: touchpadMode ? "hand.tap" : "rectangle.on.rectangle")
                        }
                        Button {
                            app.settings.showScrollHelpers.toggle()
                        } label: {
                            Label(app.settings.showScrollHelpers ? "Hide Scroll Helpers" : "Show Scroll Helpers", systemImage: "arrow.up.and.down")
                        }
                        Menu {
                            ForEach(RDQualityPreset.allCases) { preset in
                                Button {
                                    app.settings.qualityRaw = preset.rawValue
                                    session.setQuality(preset, showRemoteCursor: app.settings.showRemoteCursor)
                                } label: {
                                    if app.settings.qualityRaw == preset.rawValue {
                                        Label(preset.label, systemImage: "checkmark")
                                    } else {
                                        Text(preset.label)
                                    }
                                }
                            }
                        } label: {
                            let currentLabel = RDQualityPreset.from(app.settings.qualityRaw).label
                            Label("Quality: \(currentLabel)", systemImage: "sparkles")
                        }
                        Menu {
                            let speeds: [(label: String, value: Double)] = [("Slow", 1.0), ("Normal", 1.5), ("Fast", 2.0)]
                            ForEach(speeds, id: \.value) { speed in
                                Button {
                                    app.settings.pointerSpeedMultiplier = speed.value
                                } label: {
                                    if app.settings.pointerSpeedMultiplier == speed.value {
                                        Label(speed.label, systemImage: "checkmark")
                                    } else {
                                        Text(speed.label)
                                    }
                                }
                            }
                        } label: {
                            let currentSpeedLabel = app.settings.pointerSpeedMultiplier == 2.0 ? "Fast" : (app.settings.pointerSpeedMultiplier == 1.5 ? "Normal" : "Slow")
                            Label("Pointer Speed: \(currentSpeedLabel)", systemImage: "cursorarrow.motionlines")
                        }
                        Button(role: .destructive) {
                            onDismiss()
                        } label: {
                            Label("Disconnect", systemImage: "xmark.circle")
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.title2)
                            .frame(width: 50, height: 50)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 0.5))
                            .foregroundStyle(.white)
                            .shadow(radius: 4)
                    }
                    
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
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if session.phase == .connected && keyboardVisible {
                KeyBar(modifiers: $modifiers) { key, mods in
                    session.keyTap(key, modifiers: mods)
                }
                .background(.ultraThinMaterial)
            }
        }
        .onAppear {
            session.onSampleBuffer = { [weak canvasController] sampleBuffer, width, height in
                canvasController?.canvas?.displaySampleBuffer(sampleBuffer, width: width, height: height)
            }
            session.onCursorMoved = { [weak canvasController] point in
                virtualCursor = point
                if touchpadMode {
                    if !app.settings.showRemoteCursor {
                        canvasController?.canvas?.showCursor(at: point)
                    }
                    canvasController?.canvas?.centerOn(remotePoint: point)
                }
            }
        }
        .onChange(of: touchpadMode) { isTrackpad in
            if isTrackpad {
                let size = session.remoteSize
                if virtualCursor == .zero && size.width > 0 && size.height > 0 {
                    virtualCursor = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
                }
                if !app.settings.showRemoteCursor && virtualCursor != .zero {
                    canvasController.canvas?.showCursor(at: virtualCursor)
                }
            } else {
                canvasController.canvas?.hideCursor()
            }
        }
        .onChange(of: app.settings.showRemoteCursor) { showRemote in
            if showRemote || !touchpadMode {
                canvasController.canvas?.hideCursor()
            } else if virtualCursor != .zero {
                canvasController.canvas?.showCursor(at: virtualCursor)
            }
        }
    }

    // MARK: Handlers

    private var directTapHandler: ((CGPoint) -> Void)? {
        session.phase == .connected && !touchpadMode ? { point in
            session.click(button: 0, atRemote: point)
        } : nil
    }

    private var directRightTapHandler: ((CGPoint) -> Void)? {
        session.phase == .connected && !touchpadMode ? { point in
            session.click(button: 1, atRemote: point)
        } : nil
    }

    private var dragHandler: ((DragEvent) -> Void)? {
        session.phase == .connected ? handleDragEvent : nil
    }

    private func handleDragEvent(_ event: DragEvent) {
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

    // MARK: Overlays

    @ViewBuilder
    private var stateOverlay: some View {
        switch session.phase {
        case .connecting, .negotiating:
            ZStack {
                Color.black.opacity(session.image == nil ? 0.6 : 0.35)
                    .ignoresSafeArea()

                VStack(spacing: 16) {
                    HStack {
                        Spacer()
                        Button {
                            onDismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                                .padding(4)
                        }
                    }
                    ProgressView()
                        .controlSize(.large)
                    Text(session.image != nil ? "Reconnecting to \(session.hostDescription)…" : "Connecting to \(session.hostDescription)…")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                    Button(role: .cancel) {
                        onDismiss()
                    } label: {
                        Text("Cancel")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.secondary)
                    .controlSize(.large)
                    .simultaneousGesture(TapGesture().onEnded {
                        onDismiss()
                    })
                }
                .padding(24)
                .frame(maxWidth: 300)
                .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 20))
                .shadow(radius: 12)
            }
        case .needPin:
            ZStack {
                Color.black.opacity(0.6)
                    .ignoresSafeArea()

                PinSheet(serverName: session.serverName,
                         errorText: session.pinError,
                         refreshToken: session.pinAttemptCounter,
                         onCancel: {
                    onDismiss()
                }) { pin, trust in
                    session.submitPIN(pin, trust: trust)
                }
            }
        case .failed(let message, let countdown):
            ZStack {
                Color.black.opacity(session.image == nil ? 0.6 : 0.4)
                    .ignoresSafeArea()

                VStack(spacing: 16) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 40))
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.primary)

                    if let countdown = countdown {
                        Text("Reconnecting in \(countdown)s…")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        Button("Reconnect Now") {
                            session.reconnect()
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Close") {
                            onDismiss()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(24)
                .frame(maxWidth: 320)
                .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 20))
                .shadow(radius: 12)
            }
        case .connected:
            if !session.hasVideoFrame && session.image == nil {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Loading display…")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 20))
                .shadow(radius: 10)
            }
        default:
            EmptyView()
        }
    }

}
