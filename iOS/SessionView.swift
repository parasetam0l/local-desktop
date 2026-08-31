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

                // Top Overlays: Debug HUD & Mac Locked Banner
                VStack(spacing: 8) {
                    if session.showDebugHUD {
                        DebugHUDView(session: session)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if session.isHostLocked {
                        HStack(spacing: 8) {
                            Image(systemName: "lock.fill")
                                .font(.subheadline)
                                .foregroundStyle(.yellow)
                            Text("Mac is Locked")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
                        .shadow(radius: 6)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.top, 16)
                .frame(maxHeight: .infinity, alignment: .top)
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
            if session.isDisplaySleeping {
                VStack(spacing: 14) {
                    Image(systemName: "moon.stars.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.indigo)
                    Text("Mac Display is Sleeping")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Tap anywhere to wake the screen")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                    Button {
                        session.wakeHostDisplay()
                    } label: {
                        Label("Wake Display", systemImage: "sun.max.fill")
                    }
                    .glassButton(variant: .primary, size: .regular)
                }
                .padding(28)
                .glassCard(cornerRadius: 24, opacity: 0.25, shadowRadius: 20)
                .contentShape(Rectangle())
                .onTapGesture {
                    session.wakeHostDisplay()
                }
            } else if !session.hasVideoFrame && session.image == nil {
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
    @State private var showHardwareSheet = false

    var body: some View {
        Menu {
            Button {
                showHardwareSheet = true
            } label: {
                Label("Mac Hardware Controls…", systemImage: "slider.horizontal.3")
            }

            Button {
                withAnimation {
                    session.showDebugHUD.toggle()
                }
            } label: {
                Label(session.showDebugHUD ? "Hide Performance HUD" : "Show Performance HUD",
                      systemImage: "chart.xyaxis.line")
            }

            Divider()

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
        .sheet(isPresented: $showHardwareSheet) {
            MacHardwareControlsSheet(session: session, isPresented: $showHardwareSheet)
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

// MARK: - Performance & Debug HUD

struct DebugHUDView: View {
    @ObservedObject var session: ClientSession

    var body: some View {
        HStack(spacing: 12) {
            // FPS
            HStack(spacing: 4) {
                Text("FPS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1f", session.liveFPS > 0 ? session.liveFPS : 60.0))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(session.liveFPS >= 55 || session.liveFPS == 0 ? .green : (session.liveFPS >= 30 ? .yellow : .red))
            }

            Divider()
                .frame(height: 12)

            // RTT / Ping
            HStack(spacing: 4) {
                Text("RTT")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1fms", session.currentRTT))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(session.currentRTT < 20 ? .green : (session.currentRTT < 50 ? .yellow : .red))
            }

            Divider()
                .frame(height: 12)

            // Bitrate
            HStack(spacing: 4) {
                Text("RATE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1fM", session.liveBitrateMbps))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
            }

            Divider()
                .frame(height: 12)

            // Decode Latency
            HStack(spacing: 4) {
                Text("DEC")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1fms", session.liveDecodeMs))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(session.liveDecodeMs < 8 ? .green : (session.liveDecodeMs < 16 ? .yellow : .red))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
        .shadow(radius: 6)
    }
}

// MARK: - Mac Hardware Controls Sheet

struct MacHardwareControlsSheet: View {
    @ObservedObject var session: ClientSession
    @Binding var isPresented: Bool

    @State private var localBrightness: Float = 0.5
    @State private var isDraggingBrightness = false
    @State private var localVolume: Double = 50
    @State private var isDraggingVolume = false

    var body: some View {
        VStack(spacing: 0) {
            // Clean Custom Header
            HStack {
                Text("Mac Hardware")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)

                Spacer()

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.secondary.opacity(0.18), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 16) {
                    // Brightness Control
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Display Brightness", systemImage: "sun.max.fill")
                                .font(.headline)
                            Spacer()
                            Text("\(Int(localBrightness * 100))%")
                                .font(.subheadline.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 12) {
                            Image(systemName: "sun.min")
                                .foregroundStyle(.secondary)
                            Slider(
                                value: $localBrightness,
                                in: 0...1,
                                onEditingChanged: { editing in
                                    isDraggingBrightness = editing
                                    if !editing {
                                        session.setBrightness(localBrightness)
                                    }
                                }
                            )
                            Image(systemName: "sun.max.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                    .glassCard(cornerRadius: 16, opacity: 0.12)

                    // Volume Control
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("System Volume", systemImage: session.hardwareControls.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.headline)
                            Spacer()
                            Text(session.hardwareControls.isMuted ? "Muted" : "\(Int(localVolume))%")
                                .font(.subheadline.monospacedDigit().weight(.semibold))
                                .foregroundStyle(session.hardwareControls.isMuted ? .red : .secondary)
                        }

                        HStack(spacing: 12) {
                            Button {
                                session.setMuted(!session.hardwareControls.isMuted)
                            } label: {
                                Image(systemName: session.hardwareControls.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                    .foregroundStyle(session.hardwareControls.isMuted ? .red : .primary)
                                    .font(.title3)
                                    .frame(width: 32, height: 32)
                            }

                            Slider(
                                value: $localVolume,
                                in: 0...100,
                                onEditingChanged: { editing in
                                    isDraggingVolume = editing
                                    if !editing {
                                        session.setVolume(Int(localVolume))
                                    }
                                }
                            )

                            Text("\(Int(localVolume))%")
                                .font(.caption.monospacedDigit())
                                .frame(width: 36, alignment: .trailing)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                    .glassCard(cornerRadius: 16, opacity: 0.12)

                    // Display & Power Actions
                    VStack(spacing: 12) {
                        Button {
                            session.lockHostScreen()
                            isPresented = false
                        } label: {
                            Label("Lock Mac Screen", systemImage: "lock.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .glassButton(variant: .secondary, size: .regular, isFullWidth: true)

                        Button {
                            session.sleepHostDisplay()
                        } label: {
                            Label("Sleep Mac Display", systemImage: "moon.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .glassButton(variant: .secondary, size: .regular, isFullWidth: true)

                        Button {
                            session.wakeHostDisplay()
                        } label: {
                            Label("Wake Mac Display", systemImage: "sun.horizon.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .glassButton(variant: .secondary, size: .regular, isFullWidth: true)
                    }
                    .padding(16)
                    .glassCard(cornerRadius: 16, opacity: 0.12)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
        .onAppear {
            localBrightness = session.hardwareControls.brightness
            localVolume = Double(session.hardwareControls.volume)
            session.requestHardwareControls()
        }
        .onChange(of: session.hardwareControls) { _, newControls in
            if !isDraggingBrightness {
                localBrightness = newControls.brightness
            }
            if !isDraggingVolume {
                localVolume = Double(newControls.volume)
            }
        }
    }
}
