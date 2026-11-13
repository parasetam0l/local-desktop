import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var updater: AppUpdater
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private static let pointerSpeeds: [(label: String, value: Double)] = [("Slow", 1.0), ("Normal", 1.5), ("Fast", 2.0)]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    displaySection
                    touchSection
                    keyboardSection
                    clipboardSection
                    connectionSection
                    trustedSection
                    updatesSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
        .onChange(of: app.settings.qualityRaw) {
            app.applyQualitySettings()
        }
        .onChange(of: app.settings.codecRaw) {
            app.applyQualitySettings()
        }
        .onChange(of: app.settings.showRemoteCursor) {
            app.applyQualitySettings()
        }
        .sessionPage()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.headline)
            Spacer()
            Button("Done") {
                dismiss()
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(SessionStyle.accent)
        }
        .padding(.horizontal, 18)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    // MARK: Sections

    private var displaySection: some View {
        PanelSection("Display", footer: "Desktop size lays the Mac's desktop out at that size for each session, and the Mac's own screen shows the same layout. A size that fills the screen follows it when you turn the device. Full screen hides the status bar and dims the home indicator during sessions; swipes from the screen's edges then need a second swipe.") {
            PanelMenuRow(title: "Default quality", value: app.settings.preset.shortLabel) {
                Picker("Default quality", selection: $app.settings.qualityRaw) {
                    ForEach(RDQualityPreset.allCases) { preset in
                        Text(preset.label).tag(preset.rawValue)
                    }
                }
            }
            PanelMenuRow(title: "Default desktop size", value: app.settings.defaultDesktopSize.name) {
                Picker("Default desktop size", selection: $app.settings.defaultDesktopSize) {
                    Text("Mac's own size").tag(DesktopSizeChoice.macOwn)
                    Section(DesktopSizeChoice.fillsDeviceTitle) {
                        ForEach(DesktopSizeChoice.deviceOptions, id: \.choice) { option in
                            Text(desktopSizeLabel(option.choice, name: option.name)).tag(option.choice)
                        }
                    }
                    Section("Standard sizes") {
                        ForEach(DesktopSizeChoice.standardSizes, id: \.self) { size in
                            Text(desktopSizeLabel(.standard(size), name: nil)).tag(DesktopSizeChoice.standard(size))
                        }
                    }
                }
            }
            PanelMenuRow(title: "Video codec", value: app.settings.codec.label) {
                Picker("Video codec", selection: $app.settings.codecRaw) {
                    Text("HEVC / H.265 (recommended)").tag(RDCodec.hevc.rawValue)
                    Text("H.264").tag(RDCodec.h264.rawValue)
                }
            }
            PanelToggleRow(title: "Hide the Mac's Dock during sessions",
                           isOn: Binding(get: { app.settings.hideDock ?? false }, set: { app.settings.hideDock = $0 }))
            PanelToggleRow(title: "Full screen during sessions",
                           isOn: Binding(get: { app.settings.fullScreen ?? true }, set: { app.settings.fullScreen = $0 }))
            HandleSizeRow(app: app)
            HandleOpacityRow(app: app)
        }
    }

    @State private var showGestures = false

    private var touchSection: some View {
        PanelSection("Touch", footer: "Touchpad mode moves a pointer like a trackpad; direct touch clicks right where your finger is.") {
            PanelToggleRow(title: "Start sessions in touchpad mode", isOn: $app.settings.defaultTouchpad)
            PanelMenuRow(title: "Pointer speed", value: pointerSpeedLabel) {
                Picker("Pointer speed", selection: $app.settings.pointerSpeedMultiplier) {
                    ForEach(Self.pointerSpeeds, id: \.value) { speed in
                        Text(speed.label).tag(speed.value)
                    }
                }
            }
            PanelToggleRow(title: "Show the Mac's cursor", isOn: $app.settings.showRemoteCursor)
            PanelToggleRow(title: "One-finger drag scrolls in direct touch", isOn: $app.settings.isOneFingerScroll)
            PanelToggleRow(title: "Lock zoom", isOn: $app.settings.isZoomLocked)
            PanelToggleRow(title: "Lock orientation", isOn: $app.isOrientationLocked)
            PanelButtonRow(title: "Gestures", symbol: "questionmark.circle") {
                showGestures = true
            }
            .sheet(isPresented: $showGestures) {
                GestureGuideView(app: app, isPresented: $showGestures)
            }
        }
    }

    private var keyboardSection: some View {
        let autoKeyboardEnabled = app.settings.autoKeyboard ?? true
        return PanelSection("Keyboard", footer: "The on-screen keyboard opens by itself when a tap or click lands in a text field on the Mac.") {
            PanelToggleRow(title: "Show keyboard for text fields",
                           isOn: Binding(get: { app.settings.autoKeyboard ?? true }, set: { app.settings.autoKeyboard = $0 }))
            PanelToggleRow(title: "Show keyboard in touchpad mode",
                           isOn: Binding(get: { app.settings.autoKeyboardInTouchpad ?? true },
                                         set: { app.settings.autoKeyboardInTouchpad = $0 }))
                .disabled(!autoKeyboardEnabled)
                .opacity(autoKeyboardEnabled ? 1 : 0.45)
        }
    }

    private var clipboardSection: some View {
        PanelSection("Clipboard", footer: "Text and images copied on the Mac or on this device during a session goes to the other one's clipboard. What was already copied before a session isn't shared. iOS may ask before the Mac gets text you copied here.") {
            PanelToggleRow(title: "Share clipboard",
                           isOn: Binding(get: { app.settings.shareClipboard ?? false }, set: { app.settings.shareClipboard = $0 }))
        }
    }

    private var connectionSection: some View {
        PanelSection("Connection", footer: "Auto-connect joins the most recently used Mac as soon as it appears on the network.") {
            PanelToggleRow(title: "Auto-connect to the last Mac", isOn: $app.settings.autoConnect)
            PanelToggleRow(title: "Reconnect automatically after drops", isOn: $app.settings.autoReconnect)
        }
    }

    private var trustedSection: some View {
        PanelSection("Trusted Macs", footer: "Forgetting a Mac here only removes its pairing from this device. Revoke access on the Mac itself to block this device.") {
            if app.recents.isEmpty {
                PanelRow {
                    Text("No Macs yet")
                        .foregroundStyle(SessionStyle.secondaryText)
                    Spacer()
                }
            } else {
                ForEach(app.recents) { recent in
                    PanelRow {
                        Text(recent.name)
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        if app.isPaired(recent.serverId) {
                            Text("Paired")
                                .foregroundStyle(SessionStyle.secondaryText)
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(SessionStyle.accent)
                        }
                    }
                }
            }
            Button(role: .destructive) {
                app.forgetAllHosts()
            } label: {
                PanelRow {
                    Text("Forget all trusted Macs")
                        .foregroundStyle(SessionStyle.danger)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var updatesSection: some View {
        PanelSection("Updates", footer: updateStatus) {
            PanelRow {
                Text("Version")
                Spacer(minLength: 12)
                Text(AppUpdater.currentVersion)
                    .foregroundStyle(SessionStyle.secondaryText)
            }
            if let version = updater.availableVersion {
                if let notes = updater.releaseNotesURL(for: version) {
                    PanelButtonRow(title: "What's new in \(version)", symbol: "arrow.up.right") {
                        openURL(notes)
                    }
                }
                PanelButtonRow(title: "Install LocalDesktop \(version)", symbol: "arrow.down.circle") {
                    // The main screen's banner then shows how to finish.
                    guard let url = updater.beginInstall() else { return }
                    dismiss()
                    openURL(url) { accepted in
                        if !accepted { updater.endInstall() }
                    }
                }
            }
            Button {
                Task { await updater.check() }
            } label: {
                PanelRow {
                    Text("Check for updates")
                    Spacer(minLength: 12)
                    if updater.isChecking {
                        ProgressView()
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(updater.isChecking)
        }
    }

    /// A size as it is for the way the device is held now.
    private func desktopSizeLabel(_ choice: DesktopSizeChoice, name: String?) -> String {
        let size = choice.size(for: DesktopSizeChoice.currentPictureArea)?.label
        return [name, size].compactMap { $0 }.joined(separator: " · ")
    }

    private var pointerSpeedLabel: String {
        Self.pointerSpeeds.first { $0.value == app.settings.pointerSpeedMultiplier }?.label ?? "Custom"
    }

    private var updateStatus: String {
        if updater.lastCheckFailed {
            return "Couldn't check for updates. Check the internet connection and try again."
        }
        if updater.availableVersion != nil {
            return "Installing replaces this version and keeps paired Macs and settings. Use the same version on the Mac."
        }
        return "New versions are offered on the main screen. Keep the Mac on the same version."
    }
}
