import SwiftUI
import AppKit

/// Something sharing still needs before it can start.
enum SetupItem: Hashable, Identifiable {
    case permission(PermissionKind)
    case pin

    var id: Self { self }

    var title: String {
        switch self {
        case .permission(let kind): return "\(kind.title) not allowed"
        case .pin: return "No PIN set"
        }
    }

    var symbol: String {
        switch self {
        case .permission(.screenRecording): return "rectangle.dashed.badge.record"
        case .permission(.accessibility): return "accessibility"
        case .pin: return "lock.shield"
        }
    }
}

/// Everything the menu bar panel shows, as plain values.
struct MenuBarState {
    var isSharing = false
    var clientName: String?
    var address: String?
    var computerName = ""
    var fingerprint = ""
    var missingSetup: [SetupItem] = []
    var failedPINAttempts = 0
    var pinLockedUntil: Date?
    var lastError: String?
    var hasPIN = false
    var preset: RDQualityPreset = .high
    var codec: RDCodec = .hevc
    var displays: [RDDisplay] = []
    var selectedDisplay: CGDirectDisplayID?
    var blocksLocalInput = false
    var isBlockingLocalInput = false
    var localInputBlockError: String?
    var devices: [TrustedDevice] = []
    var launchAtLogin = false
    var launchNeedsApproval = false
    var launchError: String?
    var appVersion = ""
    /// False in development builds, which don't check for updates.
    var updaterAvailable = false
    var canCheckForUpdates = false
    var checksForUpdatesAutomatically = false
    /// A version found by a scheduled check, waiting for the user.
    var pendingUpdateVersion: String?
    var backgroundCheckResult: String?

    var canStartSharing: Bool { missingSetup.isEmpty }
}

/// What the panel can ask the app to do.
struct MenuBarActions {
    typealias Action<T> = @MainActor @Sendable (T) -> Void
    typealias Command = @MainActor @Sendable () -> Void

    var setSharing: Action<Bool> = { _ in }
    var openSetup: Command = {}
    var setPreset: Action<RDQualityPreset> = { _ in }
    var setCodec: Action<RDCodec> = { _ in }
    var setDisplay: Action<CGDirectDisplayID> = { _ in }
    var setBlocksLocalInput: Action<Bool> = { _ in }
    var revoke: Action<String> = { _ in }
    var changePIN: @MainActor @Sendable (String) async -> Void = { _ in }
    var clearLockout: Command = {}
    var dismissError: Command = {}
    var setLaunchAtLogin: Action<Bool> = { _ in }
    var openLoginItems: Command = {}
    var checkForUpdates: Command = {}
    var setChecksForUpdatesAutomatically: Action<Bool> = { _ in }
    var quit: Command = {}
}

/// The menu bar panel.
struct MenuBarContent: View {
    let state: MenuBarState
    let actions: MenuBarActions

    @State private var isChangingPIN = false
    @State private var newPIN = ""
    @State private var confirmPIN = ""
    @State private var isSavingPIN = false
    @State private var copiedAddress = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 16) {
                if !state.missingSetup.isEmpty {
                    setupCallout
                }
                if let version = state.pendingUpdateVersion {
                    updateBanner(version)
                }
                if let error = state.lastError {
                    errorBanner(error)
                }
                if state.failedPINAttempts > 0 {
                    lockoutBanner
                }

                thisMacCard
                if state.isSharing {
                    streamCard
                }
                devicesCard

                footer
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(width: 360)
        .foregroundStyle(PanelStyle.primaryText)
        .tint(PanelStyle.accent)
        .background(PanelStyle.panel)
    }

    // MARK: Header

    private var statusText: String {
        if !state.isSharing { return state.canStartSharing ? "Sharing is off" : "Setup needed" }
        if let client = state.clientName { return "Controlled by \(client)" }
        return "Waiting for a device"
    }

    private var statusSymbol: String {
        if !state.isSharing { return "desktopcomputer" }
        return state.clientName == nil ? "dot.radiowaves.left.and.right" : "iphone.radiowaves.left.and.right"
    }

    private var statusColor: Color {
        if !state.isSharing { return PanelStyle.secondaryText }
        return state.clientName == nil ? PanelStyle.accent : .green
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: statusSymbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 34, height: 34)
                .background(statusColor.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text("LocalDesktop")
                    .font(.headline)
                HStack(spacing: 6) {
                    // The iOS session header's status dot.
                    if state.isSharing {
                        Circle()
                            .fill(state.clientName == nil ? Color.orange : Color.green)
                            .frame(width: 7, height: 7)
                    }
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(PanelStyle.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer()
            Toggle("Sharing", isOn: Binding(get: { state.isSharing }, set: { [actions] in actions.setSharing($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!state.isSharing && !state.canStartSharing)
                .help(state.isSharing ? "Stop sharing" : "Start sharing")
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    // MARK: Banners

    private var setupCallout: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Finish setup to start sharing")
                .font(.subheadline.weight(.semibold))
            ForEach(state.missingSetup) { item in
                Label(item.title, systemImage: item.symbol)
                    .font(.subheadline)
                    .foregroundStyle(PanelStyle.secondaryText)
            }
            Button("Open Setup Assistant…", action: actions.openSetup)
                .buttonStyle(PanelButtonStyle(prominent: true))
                .padding(.top, 2)
        }
        .panelNotice(.orange)
    }

    private func updateBanner(_ version: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(PanelStyle.accent)
            Text("Version \(version) is available")
                .font(.subheadline.weight(.medium))
            Spacer()
            Button("Update…", action: actions.checkForUpdates)
                .buttonStyle(PanelButtonStyle(compact: true))
        }
        .panelNotice(PanelStyle.accent)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(PanelStyle.danger)
            Text(message)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                actions.dismissError()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PanelStyle.secondaryText)
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .panelNotice(PanelStyle.danger)
    }

    private var lockoutBanner: some View {
        let locked = state.pinLockedUntil.map { $0 > Date() } ?? false
        let attempts = "\(state.failedPINAttempts) wrong PIN \(state.failedPINAttempts == 1 ? "attempt" : "attempts")"
        return HStack(spacing: 8) {
            Image(systemName: locked ? "lock.trianglebadge.exclamationmark.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(locked ? PanelStyle.danger : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(attempts)
                    .font(.subheadline.weight(.medium))
                if locked, let until = state.pinLockedUntil {
                    Text("PIN entry locked until \(until.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(PanelStyle.secondaryText)
                }
            }
            Spacer()
            Button(locked ? "Unlock" : "Clear", action: actions.clearLockout)
                .buttonStyle(PanelButtonStyle(compact: true))
        }
        .panelNotice(locked ? PanelStyle.danger : .orange)
    }

    // MARK: Sections

    private var thisMacCard: some View {
        PanelSection("This Mac") {
            PanelValueRow("Name") {
                Text(state.computerName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if state.isSharing, let address = state.address {
                PanelValueRow("Address") {
                    HStack(spacing: 6) {
                        Text(address)
                            .font(.body.monospaced())
                            .lineLimit(1)
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(address, forType: .string)
                            copiedAddress = true
                        } label: {
                            Image(systemName: copiedAddress ? "checkmark" : "doc.on.doc")
                                .font(.caption)
                                .foregroundStyle(copiedAddress ? PanelStyle.accent : PanelStyle.secondaryText)
                        }
                        .buttonStyle(.borderless)
                        .help("Copy address")
                    }
                }
            }
            PanelValueRow("Fingerprint") {
                Text(state.fingerprint)
                    .font(.body.monospaced())
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .help("Your iPhone shows the same fingerprint when pairing. Only enter the PIN if they match.")

            if isChangingPIN {
                pinEditor
            } else {
                PanelValueRow("PIN") {
                    HStack(spacing: 8) {
                        Text(state.hasPIN ? "••••" : "Not set")
                        Button(state.hasPIN ? "Change…" : "Set…") {
                            isChangingPIN = true
                        }
                        .buttonStyle(PanelButtonStyle(compact: true))
                    }
                }
            }
        }
    }

    private var pinValid: Bool {
        PINHasher.isValidFormat(newPIN) && newPIN == confirmPIN
    }

    private var pinEditor: some View {
        PanelRow(verticalPadding: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Text(state.hasPIN ? "New PIN" : "Choose a PIN")
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 8) {
                    SecureField("4 digits", text: $newPIN)
                    SecureField("Confirm", text: $confirmPIN)
                }
                .textFieldStyle(.roundedBorder)
                .font(.body.monospacedDigit())
                HStack(spacing: 6) {
                    Text(!newPIN.isEmpty && !PINHasher.isValidFormat(newPIN) ? "Use exactly 4 digits."
                         : (!confirmPIN.isEmpty && confirmPIN != newPIN ? "The PINs don't match." : " "))
                        .font(.caption)
                        .foregroundStyle(PanelStyle.danger)
                    Spacer()
                    Button("Cancel") { endPINEditing() }
                        .buttonStyle(PanelButtonStyle(compact: true))
                    Button("Save") {
                        let pin = newPIN
                        isSavingPIN = true
                        Task {
                            await actions.changePIN(pin)
                            isSavingPIN = false
                            endPINEditing()
                        }
                    }
                    .buttonStyle(PanelButtonStyle(prominent: true, compact: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!pinValid || isSavingPIN)
                }
            }
        }
    }

    private func endPINEditing() {
        isChangingPIN = false
        newPIN = ""
        confirmPIN = ""
    }

    private var localInputFooter: String {
        if let error = state.localInputBlockError { return error }
        if state.isBlockingLocalInput { return "Blocked now. Only connected devices can type and click." }
        return "While a device is connected. Input comes back when the last one disconnects."
    }

    private var streamCard: some View {
        PanelSection("Stream", footer: localInputFooter, footerIsWarning: state.localInputBlockError != nil) {
            PanelValueRow("Quality") {
                Picker("Quality", selection: Binding(get: { state.preset }, set: { [actions] in actions.setPreset($0) })) {
                    ForEach(RDQualityPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            PanelValueRow("Codec") {
                Picker("Codec", selection: Binding(get: { state.codec }, set: { [actions] in actions.setCodec($0) })) {
                    ForEach(RDCodec.allCases) { codec in
                        Text(codec.label).tag(codec)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            if state.displays.count > 1 {
                PanelValueRow("Display") {
                    Picker("Display", selection: Binding(
                        get: { state.selectedDisplay ?? state.displays.first?.id ?? 0 },
                        set: { [actions] in actions.setDisplay($0) }
                    )) {
                        ForEach(state.displays) { display in
                            Text("\(display.name) · \(display.resolution)").tag(display.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            PanelRow {
                Toggle("Block this Mac's keyboard and trackpad",
                       isOn: Binding(get: { state.blocksLocalInput }, set: { [actions] in actions.setBlocksLocalInput($0) }))
                    .toggleStyle(.switch)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .controlSize(.small)
    }

    private var devicesCard: some View {
        PanelSection("Trusted Devices",
                     footer: state.devices.isEmpty
                        ? "A device is added here after it connects with the PIN and chooses to be trusted."
                        : "A revoked device needs the PIN again to connect.") {
            if state.devices.isEmpty {
                PanelRow {
                    Text("None yet")
                        .foregroundStyle(PanelStyle.secondaryText)
                    Spacer()
                }
            } else {
                ForEach(state.devices) { device in
                    PanelRow(verticalPadding: 6) {
                        Image(systemName: device.name.localizedCaseInsensitiveContains("ipad") ? "ipad" : "iphone")
                            .foregroundStyle(PanelStyle.secondaryText)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.name)
                                .lineLimit(1)
                            Text("Trusted \(device.trustedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption)
                                .foregroundStyle(PanelStyle.secondaryText)
                        }
                        Spacer(minLength: 12)
                        Button("Revoke") { actions.revoke(device.id) }
                            .buttonStyle(PanelButtonStyle(destructive: true, compact: true))
                            .help("This device will need the PIN again")
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let result = state.backgroundCheckResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(PanelStyle.secondaryText)
            }
            HStack(spacing: 8) {
                Text("Version \(state.appVersion)")
                    .font(.caption)
                    .foregroundStyle(PanelStyle.secondaryText)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Spacer()
                Menu {
                    Button(state.updaterAvailable ? "Check for Updates…" : "Check for Updates… (release builds only)",
                           action: actions.checkForUpdates)
                        .disabled(!state.canCheckForUpdates)
                    Toggle("Check for Updates Automatically", isOn: Binding(
                        get: { state.checksForUpdatesAutomatically },
                        set: { [actions] in actions.setChecksForUpdatesAutomatically($0) }
                    ))
                    .disabled(!state.updaterAvailable)
                    Divider()
                    Toggle("Open at Login", isOn: Binding(get: { state.launchAtLogin }, set: { [actions] in actions.setLaunchAtLogin($0) }))
                    Button("Setup Assistant…", action: actions.openSetup)
                    Divider()
                    Button("Quit LocalDesktop…") { confirmQuit() }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Updates, settings and Quit")
            }
            .controlSize(.small)
            .padding(.horizontal, 4)
            if state.launchNeedsApproval {
                HStack(spacing: 4) {
                    Text("Allow it in Login Items to open at login.")
                    Button("Open Login Items…", action: actions.openLoginItems)
                        .buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 4)
            }
            if let error = state.launchError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(PanelStyle.danger)
                    .padding(.horizontal, 4)
            }
        }
    }

    /// Asks before quitting, since a quit Mac can't be reached until someone opens the app on it.
    /// An `NSAlert` rather than a SwiftUI `.alert`: the panel is a menu bar window that closes
    /// as soon as it loses focus, and an alert attached to it would go with it (or not show).
    private func confirmQuit() {
        let quit = actions.quit
        // Let the menu finish tracking and the panel close before the alert takes over.
        Task { @MainActor in
            NSApp.activate()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Quit LocalDesktop?"
            alert.informativeText = "Connected devices will be disconnected, and this Mac can't be reached until LocalDesktop is opened again."
            // The first button is the default (Return), so Cancel goes first.
            alert.addButton(withTitle: "Cancel")
            let quitButton = alert.addButton(withTitle: "Quit")
            quitButton.hasDestructiveAction = true
            if alert.runModal() == .alertSecondButtonReturn {
                quit()
            }
        }
    }
}
