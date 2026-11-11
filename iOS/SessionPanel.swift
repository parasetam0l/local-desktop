import SwiftUI

/// Everything about the running session that isn't a frequent action, in one grouped
/// panel: a sheet on an iPhone, a popover from the control bar on an iPad.
struct SessionPanel: View {
    @Binding var touchpadMode: Bool
    @ObservedObject var app: AppModel
    @ObservedObject var session: ClientSession
    @ObservedObject var canvasController: CanvasController
    @Binding var isPresented: Bool
    var onDisconnect: () -> Void

    @State private var showHardwareSheet = false
    @State private var showGestures = false

    private static let pointerSpeeds: [(label: String, value: Double)] = [("Slow", 1.0), ("Normal", 1.5), ("Fast", 2.0)]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Most used first: touch, then the Mac's desktop; the stream's
                    // settings, rarely changed, last.
                    touchSection
                    macSection
                    if canvasController.isPiPSupported {
                        pictureInPictureSection
                    }
                    streamSection
                    Button(role: .destructive) {
                        isPresented = false
                        onDisconnect()
                    } label: {
                        Text("Disconnect")
                            .font(.body.weight(.medium))
                            .foregroundStyle(SessionStyle.danger)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(SessionStyle.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
        .background(SessionStyle.panel.ignoresSafeArea())
        .foregroundStyle(.white)
        .tint(SessionStyle.accent)
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(SessionStyle.panel)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.phase == .connected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(session.serverName.isEmpty ? "Session" : session.serverName)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            if session.liveFPS > 0 {
                Text("\(Int(session.liveFPS.rounded())) fps · \(Int(session.currentRTT.rounded())) ms")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(SessionStyle.secondaryText)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    // MARK: Sections

    private var macSection: some View {
        PanelSection("Mac", footer: session.sizedMirrorAvailable && session.mirrorSize != nil
                     ? "The Mac's own screen shows the same layout while a desktop size is on." : nil) {
            if session.sizedMirrorAvailable {
                PanelMenuRow(title: "Desktop size", value: session.mirrorSize?.label ?? "Mac's own") {
                    checkButton("Mac's own size", isOn: session.mirrorSize == nil) {
                        session.setDesktopSize(.macOwn)
                    }
                    // Sizes as they are for the way the device is held now; the choice
                    // follows when it is turned.
                    Section(DesktopSizeChoice.fillsDeviceTitle) {
                        ForEach(DesktopSizeChoice.deviceOptions, id: \.choice) { option in
                            desktopSizeButton(option.choice, name: option.name)
                        }
                    }
                    Section("Standard sizes") {
                        ForEach(DesktopSizeChoice.standardSizes, id: \.self) { size in
                            desktopSizeButton(.standard(size), name: nil)
                        }
                    }
                }
            }
            // Empty with a Mac older than 1.2.1, which doesn't send its displays.
            if session.displays.count > 1 {
                let current = session.displays.first { $0.id == session.selectedDisplayId }
                PanelMenuRow(title: "Screen", value: current?.name ?? "Choose") {
                    ForEach(session.displays) { display in
                        checkButton("\(display.name) · \(display.resolution)",
                                    isOn: display.id == session.selectedDisplayId) {
                            session.selectDisplay(display.id)
                        }
                    }
                }
            }
            if let hidesMacDock = session.hidesMacDock {
                PanelToggleRow(title: "Hide Mac's Dock",
                               isOn: Binding(get: { hidesMacDock }, set: { session.setHidesMacDock($0) }))
            }
            PanelToggleRow(title: "Share clipboard", isOn: $session.sharesClipboard)
            PanelButtonRow(title: "Brightness and volume", symbol: "chevron.right") {
                showHardwareSheet = true
            }
            .adaptiveSheet(isPresented: $showHardwareSheet, padSize: CGSize(width: 400, height: 400)) {
                MacHardwareControlsSheet(session: session, isPresented: $showHardwareSheet)
            }
            if let blocksMacInput = session.blocksMacInput {
                PanelToggleRow(title: "Block Mac's keyboard and trackpad",
                               isOn: Binding(get: { blocksMacInput }, set: { session.setBlocksMacInput($0) }))
            }
        }
    }

    private var streamSection: some View {
        PanelSection("Stream") {
            PanelMenuRow(title: "Quality", value: app.settings.preset.shortLabel) {
                ForEach(RDQualityPreset.allCases) { preset in
                    checkButton(preset.label, isOn: app.settings.qualityRaw == preset.rawValue) {
                        app.settings.qualityRaw = preset.rawValue
                        app.applyQualitySettings()
                    }
                }
            }
            PanelMenuRow(title: "Codec", value: app.settings.codec.label) {
                ForEach(RDCodec.allCases) { codec in
                    checkButton(codec.label, isOn: app.settings.codecRaw == codec.rawValue) {
                        app.settings.codecRaw = codec.rawValue
                        app.applyQualitySettings()
                    }
                }
            }
            PanelButtonRow(title: "Refresh picture", symbol: "arrow.triangle.2.circlepath") {
                session.requestKeyframe(reason: "user_refresh")
            }
            PanelToggleRow(title: "Performance readout",
                           isOn: Binding(get: { session.showDebugHUD },
                                         set: { on in withAnimation { session.showDebugHUD = on } }))
        }
    }

    private var touchSection: some View {
        PanelSection("Touch", footer: touchpadMode
                     ? "Touchpad: drag anywhere to move the pointer, tap to click."
                     : "Direct touch: tap and drag right where your finger is.") {
            PanelRow {
                Picker("Mode", selection: $touchpadMode) {
                    Text("Direct touch").tag(false)
                    Text("Touchpad").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if touchpadMode {
                PanelRow {
                    Text("Pointer speed")
                    Spacer(minLength: 12)
                    Picker("Pointer speed", selection: $app.settings.pointerSpeedMultiplier) {
                        ForEach(Self.pointerSpeeds, id: \.value) { speed in
                            Text(speed.label).tag(speed.value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 200)
                }
                PanelToggleRow(title: "Scroll buttons", isOn: $app.settings.showScrollHelpers)
            } else {
                PanelToggleRow(title: "One-finger scroll", isOn: $app.settings.isOneFingerScroll)
            }
            PanelToggleRow(title: "Lock zoom", isOn: $app.settings.isZoomLocked)
            PanelToggleRow(title: "Lock orientation", isOn: $app.isOrientationLocked)
            PanelButtonRow(title: "Gestures", symbol: "questionmark.circle") {
                showGestures = true
            }
            .adaptiveSheet(isPresented: $showGestures, padSize: CGSize(width: 400, height: 560)) {
                GestureGuideView(app: app, isPresented: $showGestures)
            }
        }
    }

    private var pictureInPictureSection: some View {
        PanelSection("Picture in picture") {
            PanelButtonRow(title: canvasController.isPiPActive ? "Exit picture in picture" : "Start picture in picture",
                           symbol: canvasController.isPiPActive ? "pip.exit" : "pip.enter") {
                canvasController.togglePiP()
            }
            PanelToggleRow(title: "Start when leaving the app", isOn: $canvasController.isAutoPiPEnabled)
        }
    }

    @ViewBuilder
    private func desktopSizeButton(_ choice: DesktopSizeChoice, name: String?) -> some View {
        if let size = choice.size(for: session.pictureArea) {
            checkButton(name.map { "\($0) · \(size.label)" } ?? size.label, isOn: size == session.mirrorSize) {
                session.setDesktopSize(choice)
            }
        }
    }

    @ViewBuilder
    private func checkButton(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isOn {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

// MARK: - Building blocks

/// A titled group of rows on one rounded surface, with hairlines between the rows.
struct PanelSection<Content: View>: View {
    let title: String
    let footer: String?
    @ViewBuilder let content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(SessionStyle.secondaryText)
                .padding(.horizontal, 4)
            _VariadicView.Tree(PanelRowsLayout()) { content }
                .background(SessionStyle.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(SessionStyle.secondaryText)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Stacks a section's rows and draws a hairline between each two.
private struct PanelRowsLayout: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        VStack(spacing: 0) {
            ForEach(children) { child in
                child
                if child.id != last {
                    Rectangle()
                        .fill(SessionStyle.hairline)
                        .frame(height: 0.5)
                        .padding(.leading, 14)
                }
            }
        }
    }
}

struct PanelRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .font(.subheadline)
            .padding(.horizontal, 14)
            .frame(minHeight: 46)
    }
}

struct PanelToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        PanelRow {
            Toggle(title, isOn: $isOn)
        }
    }
}

struct PanelButtonRow: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PanelRow {
                Text(title)
                Spacer(minLength: 12)
                Image(systemName: symbol)
                    .foregroundStyle(SessionStyle.secondaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A row that shows its current value and opens a menu of choices.
struct PanelMenuRow<Choices: View>: View {
    let title: String
    let value: String
    @ViewBuilder let choices: Choices

    var body: some View {
        Menu {
            choices
        } label: {
            PanelRow {
                Text(title)
                    .foregroundStyle(.white)
                Spacer(minLength: 12)
                Text(value)
                    .foregroundStyle(SessionStyle.secondaryText)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(SessionStyle.secondaryText)
            }
            .contentShape(Rectangle())
        }
    }
}
