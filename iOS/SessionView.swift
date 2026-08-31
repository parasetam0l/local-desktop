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
                        if session.isDisplaySleeping {
                            session.wakeHostDisplay()
                        }
                        session.click(button: 0, atRemote: point ?? (virtualCursor != .zero ? virtualCursor : nil))
                    },
                    onRightClick: { point in
                        if session.isDisplaySleeping {
                            session.wakeHostDisplay()
                        }
                        session.click(button: 1, atRemote: point ?? (virtualCursor != .zero ? virtualCursor : nil))
                    },
                    onScroll: { dx, dy in
                        session.scroll(dx: dx, dy: dy)
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
                    },
                    onArrowKey: { key in
                        session.keyTap(key, modifiers: modifiers)
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

                // Status banner when Mac is locked
                if session.phase == .connected && session.isHostLocked {
                    HStack(spacing: 10) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.yellow)
                        Text("Mac is Locked")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Button("Enter Password") {
                            keyboardVisible = true
                        }
                        .glassButton(variant: .tinted(.blue), size: .mini)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
                    .shadow(radius: 6)
                    .padding(.top, 16)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
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
            if session.isDisplaySleeping {
                session.wakeHostDisplay()
            }
            session.click(button: 0, atRemote: point)
        } : nil
    }

    private var directRightTapHandler: ((CGPoint) -> Void)? {
        session.phase == .connected && !touchpadMode ? { point in
            if session.isDisplaySleeping {
                session.wakeHostDisplay()
            }
            session.click(button: 1, atRemote: point)
        } : nil
    }

    private var dragHandler: ((DragEvent) -> Void)? {
        session.phase == .connected ? handleDragEvent : nil
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

    // MARK: Overlays

    @ViewBuilder
    private var stateOverlay: some View {
        switch session.phase {
        case .connecting, .negotiating:
            ZStack {
                Color.black.opacity(session.image == nil ? 0.65 : 0.4)
                    .ignoresSafeArea()

                VStack(spacing: 20) {
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.18))
                            .frame(width: 64, height: 64)
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                    }

                    VStack(spacing: 6) {
                        Text(session.image != nil ? "Reconnecting" : "Connecting")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.65))
                        Text(session.displayName)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                    }

                    Button(role: .cancel) {
                        onDismiss()
                    } label: {
                        Text("Cancel")
                    }
                    .glassButton(variant: .secondary, size: .regular, isFullWidth: true)
                    .simultaneousGesture(TapGesture().onEnded {
                        onDismiss()
                    })
                }
                .padding(28)
                .frame(maxWidth: 300)
                .glassCard(cornerRadius: 24, opacity: 0.15, shadowRadius: 24)
            }
        case .needPin:
            ZStack {
                Color.black.opacity(0.65)
                    .ignoresSafeArea()

                PinSheet(serverName: session.displayName,
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
                Color.black.opacity(session.image == nil ? 0.65 : 0.45)
                    .ignoresSafeArea()

                VStack(spacing: 20) {
                    ZStack {
                        Circle()
                            .fill(Color.red.opacity(0.18))
                            .frame(width: 64, height: 64)
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.red)
                    }

                    VStack(spacing: 6) {
                        Text(message)
                            .font(.headline.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)

                        if let countdown = countdown {
                            Text("Reconnecting in \(countdown)s…")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.65))
                        }
                    }

                    HStack(spacing: 12) {
                        Button("Reconnect Now") {
                            session.reconnect()
                        }
                        .glassButton(variant: .primary, size: .regular)

                        Button("Close") {
                            onDismiss()
                        }
                        .glassButton(variant: .secondary, size: .regular)
                    }
                }
                .padding(28)
                .frame(maxWidth: 320)
                .glassCard(cornerRadius: 24, opacity: 0.15, shadowRadius: 24)
            }
        case .connected:
            if !session.hasVideoFrame && session.image == nil {
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text("Loading display…")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(24)
                .glassCard(cornerRadius: 20, opacity: 0.15, shadowRadius: 16)
            }
        default:
            EmptyView()
        }
    }

}

// MARK: - Session Menu Button

struct SessionMenuButton: View {
    @Binding var touchpadMode: Bool
    @ObservedObject var app: AppModel
    let session: ClientSession
    @ObservedObject var canvasController: CanvasController
    let onDismiss: () -> Void

    var body: some View {
        Menu {
            Button {
                touchpadMode.toggle()
            } label: {
                Label(touchpadMode ? "Direct Mode" : "Touchpad Mode",
                      systemImage: touchpadMode ? "hand.tap" : "rectangle.on.rectangle")
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

            Button {
                app.settings.showScrollHelpers.toggle()
            } label: {
                Label(app.settings.showScrollHelpers ? "Hide Scroll Helpers" : "Show Scroll Helpers", systemImage: "arrow.up.and.down")
            }

            Divider()

            Menu {
                ForEach(RDQualityPreset.allCases) { preset in
                    Button {
                        app.settings.qualityRaw = preset.rawValue
                        let codec = RDCodec(rawValue: app.settings.codecRaw) ?? .hevc
                        session.setQuality(preset, showRemoteCursor: app.settings.showRemoteCursor, codec: codec)
                    } label: {
                        if app.settings.qualityRaw == preset.rawValue {
                            Label(preset.label, systemImage: "checkmark")
                        } else {
                            Text(preset.label)
                        }
                    }
                }
            } label: {
                let currentLabel = RDQualityPreset.from(app.settings.qualityRaw).shortLabel
                Label("Quality: \(currentLabel)", systemImage: "sparkles")
            }

            Menu {
                ForEach(RDCodec.allCases.filter { $0 != .jpeg }) { codec in
                    Button {
                        app.settings.codecRaw = codec.rawValue
                        let preset = RDQualityPreset.from(app.settings.qualityRaw)
                        session.setQuality(preset, showRemoteCursor: app.settings.showRemoteCursor, codec: codec)
                    } label: {
                        if app.settings.codecRaw == codec.rawValue {
                            Label(codec.label, systemImage: "checkmark")
                        } else {
                            Text(codec.label)
                        }
                    }
                }
            } label: {
                let currentCodec = RDCodec(rawValue: app.settings.codecRaw) ?? .hevc
                Label("Codec: \(currentCodec.label)", systemImage: "film")
            }

            if canvasController.isPiPSupported {
                Menu {
                    Button {
                        canvasController.togglePiP()
                    } label: {
                        Label(canvasController.isPiPActive ? "Exit Picture in Picture" : "Picture in Picture",
                              systemImage: canvasController.isPiPActive ? "pip.exit" : "pip.enter")
                    }
                    Button {
                        canvasController.isAutoPiPEnabled.toggle()
                    } label: {
                        if canvasController.isAutoPiPEnabled {
                            Label("Auto PiP: ON", systemImage: "checkmark")
                        } else {
                            Text("Auto PiP: OFF")
                        }
                    }
                } label: {
                    Label("Picture in Picture", systemImage: "pip")
                }
            }

            Button {
                session.requestKeyframe(reason: "user_refresh")
            } label: {
                Label("Refresh Video", systemImage: "arrow.triangle.2.circlepath")
            }

            Divider()

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
    }
}

struct AppSwitcherButton: View {
    @ObservedObject var session: ClientSession
    @State private var showSheet = false

    var body: some View {
        Button {
            showSheet = true
        } label: {
            Image(systemName: "square.stack.3d.up")
                .font(.title2)
                .frame(width: 50, height: 50)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 0.5))
                .foregroundStyle(.white)
                .shadow(radius: 4)
        }
        .sheet(isPresented: $showSheet) {
            AppSwitcherView(session: session, isPresented: $showSheet)
        }
    }
}

struct AppSwitcherView: View {
    @ObservedObject var session: ClientSession
    @Binding var isPresented: Bool
    @State private var searchText = ""

    var filteredApps: [RDRunningApp] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return session.runningApps
        }
        return session.runningApps.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Quick Action Bar
                HStack(spacing: 12) {
                    Button {
                        session.triggerSystemAction(.showDesktop)
                        isPresented = false
                    } label: {
                        Label("Show Desktop", systemImage: "macwindow.on.rectangle")
                            .font(.caption.weight(.medium))
                    }
                    .glassButton(variant: .secondary, size: .small)

                    Button {
                        session.triggerSystemAction(.missionControl)
                        isPresented = false
                    } label: {
                        Label("Mission Control", systemImage: "square.grid.2x2")
                            .font(.caption.weight(.medium))
                    }
                    .glassButton(variant: .secondary, size: .small)

                    Spacer()

                    Button {
                        session.requestRunningApps()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.subheadline)
                    }
                    .glassButton(variant: .secondary, size: .small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()

                if session.runningApps.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Querying open applications on Mac...")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(filteredApps) { app in
                                Button {
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    session.activateApp(bundleId: app.bundleId)
                                    isPresented = false
                                } label: {
                                    HStack(spacing: 14) {
                                        // Real Native App Icon
                                        if let iconData = app.iconPNG.flatMap({ Data(base64Encoded: $0) }),
                                           let uiImage = UIImage(data: iconData) {
                                            Image(uiImage: uiImage)
                                                .resizable()
                                                .aspectRatio(contentMode: .fit)
                                                .frame(width: 44, height: 44)
                                                .cornerRadius(10)
                                                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                                        } else {
                                            Image(systemName: "app.fill")
                                                .font(.title2)
                                                .frame(width: 44, height: 44)
                                                .background(Color.secondary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
                                                .foregroundStyle(.primary)
                                        }

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(app.name)
                                                .font(.body.weight(.medium))
                                                .foregroundStyle(.primary)
                                            if app.isActive {
                                                Text("Active Window")
                                                    .font(.caption2.weight(.semibold))
                                                    .foregroundStyle(.green)
                                            } else if app.isHidden {
                                                Text("Hidden")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }

                                        Spacer()

                                        if app.isActive {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.green)
                                                .font(.title3)
                                        }
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(app.isActive ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search open apps")
                }
            }
            .navigationTitle("Mac App Switcher")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        isPresented = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
        .onAppear {
            session.requestRunningApps()
        }
    }
}
