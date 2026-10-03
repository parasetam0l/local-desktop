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
    var displays: [DisplayInfo] = []
    var selectedDisplay: CGDirectDisplayID?
    var devices: [TrustedDevice] = []
    var launchAtLogin = false
    var launchNeedsApproval = false
    var launchError: String?

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
    var revoke: Action<String> = { _ in }
    var changePIN: @MainActor @Sendable (String) async -> Void = { _ in }
    var clearLockout: Command = {}
    var dismissError: Command = {}
    var setLaunchAtLogin: Action<Bool> = { _ in }
    var openLoginItems: Command = {}
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
        VStack(alignment: .leading, spacing: 12) {
            header

            if !state.missingSetup.isEmpty {
                setupCallout
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

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
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
        if !state.isSharing { return .secondary }
        return state.clientName == nil ? .blue : .green
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: statusSymbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 34, height: 34)
                .background(statusColor.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text("Local Desktop")
                    .font(.headline)
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("Sharing", isOn: Binding(get: { state.isSharing }, set: actions.setSharing))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!state.isSharing && !state.canStartSharing)
                .help(state.isSharing ? "Stop sharing" : "Start sharing")
        }
    }

    // MARK: Banners

    private var setupCallout: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Finish setup to start sharing")
                .font(.subheadline.weight(.semibold))
            ForEach(state.missingSetup) { item in
                Label(item.title, systemImage: item.symbol)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Button("Open Setup Assistant…", action: actions.openSetup)
                .buttonStyle(.borderedProminent)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.orange.opacity(0.35)))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                actions.dismissError()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(10)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var lockoutBanner: some View {
        let locked = state.pinLockedUntil.map { $0 > Date() } ?? false
        let attempts = "\(state.failedPINAttempts) wrong PIN \(state.failedPINAttempts == 1 ? "attempt" : "attempts")"
        return HStack(spacing: 8) {
            Image(systemName: locked ? "lock.trianglebadge.exclamationmark.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(locked ? .red : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(attempts)
                    .font(.subheadline.weight(.medium))
                if locked, let until = state.pinLockedUntil {
                    Text("PIN entry locked until \(until.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(locked ? "Unlock" : "Clear", action: actions.clearLockout)
                .controlSize(.small)
        }
        .padding(10)
        .background((locked ? Color.red : Color.orange).opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: Cards

    private var thisMacCard: some View {
        Card(title: "This Mac") {
            InfoRow("Name") {
                Text(state.computerName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if state.isSharing, let address = state.address {
                InfoRow("Address") {
                    HStack(spacing: 4) {
                        Text(address)
                            .font(.subheadline.monospaced())
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(address, forType: .string)
                            copiedAddress = true
                        } label: {
                            Image(systemName: copiedAddress ? "checkmark" : "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Copy address")
                    }
                }
            }
            InfoRow("Fingerprint") {
                Text(state.fingerprint)
                    .font(.subheadline.monospaced())
                    .textSelection(.enabled)
            }
            .help("Your iPhone shows the same fingerprint when pairing. Only enter the PIN if they match.")

            Divider()
            if isChangingPIN {
                pinEditor
            } else {
                InfoRow("PIN") {
                    HStack(spacing: 8) {
                        Text(state.hasPIN ? "••••" : "Not set")
                            .foregroundStyle(state.hasPIN ? .primary : .secondary)
                        Button(state.hasPIN ? "Change…" : "Set…") {
                            isChangingPIN = true
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var pinValid: Bool {
        PINHasher.isValidFormat(newPIN) && newPIN == confirmPIN
    }

    private var pinEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(state.hasPIN ? "New PIN" : "Choose a PIN")
                .font(.subheadline.weight(.medium))
            HStack(spacing: 8) {
                SecureField("4 digits", text: $newPIN)
                SecureField("Confirm", text: $confirmPIN)
            }
            .textFieldStyle(.roundedBorder)
            .font(.body.monospacedDigit())
            HStack {
                Text(!newPIN.isEmpty && !PINHasher.isValidFormat(newPIN) ? "Use exactly 4 digits."
                     : (!confirmPIN.isEmpty && confirmPIN != newPIN ? "The PINs don't match." : " "))
                    .font(.caption)
                    .foregroundStyle(.red)
                Spacer()
                Button("Cancel") { endPINEditing() }
                    .controlSize(.small)
                Button("Save") {
                    let pin = newPIN
                    isSavingPIN = true
                    Task {
                        await actions.changePIN(pin)
                        isSavingPIN = false
                        endPINEditing()
                    }
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(!pinValid || isSavingPIN)
            }
        }
    }

    private func endPINEditing() {
        isChangingPIN = false
        newPIN = ""
        confirmPIN = ""
    }

    private var streamCard: some View {
        Card(title: "Stream", controlSize: .small) {
            InfoRow("Quality") {
                Picker("Quality", selection: Binding(get: { state.preset }, set: actions.setPreset)) {
                    ForEach(RDQualityPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            InfoRow("Codec") {
                Picker("Codec", selection: Binding(get: { state.codec }, set: actions.setCodec)) {
                    ForEach(RDCodec.allCases) { codec in
                        Text(codec.label).tag(codec)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            if state.displays.count > 1 {
                InfoRow("Display") {
                    Picker("Display", selection: Binding(
                        get: { state.selectedDisplay ?? state.displays.first?.id ?? 0 },
                        set: actions.setDisplay
                    )) {
                        ForEach(Array(state.displays.enumerated()), id: \.element.id) { index, display in
                            Text("Display \(index + 1) · \(display.label)").tag(display.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }

    private var devicesCard: some View {
        Card(title: "Trusted Devices") {
            if state.devices.isEmpty {
                Text("None yet. A device is added here after it connects with the PIN and chooses to be trusted.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(state.devices) { device in
                    HStack(spacing: 10) {
                        Image(systemName: device.name.localizedCaseInsensitiveContains("ipad") ? "ipad" : "iphone")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.name)
                                .lineLimit(1)
                            Text("Trusted \(device.trustedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Revoke") { actions.revoke(device.id) }
                            .controlSize(.small)
                            .help("This device will need the PIN again")
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Open at login", isOn: Binding(get: { state.launchAtLogin }, set: actions.setLaunchAtLogin))
                    .toggleStyle(.checkbox)
                Spacer()
                if state.missingSetup.isEmpty {
                    Button("Setup Assistant…", action: actions.openSetup)
                }
                Button("Quit", action: actions.quit)
            }
            .controlSize(.small)
            if state.launchNeedsApproval {
                HStack(spacing: 4) {
                    Text("Allow it in Login Items to open at login.")
                    Button("Open Login Items…", action: actions.openLoginItems)
                        .buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }
            if let error = state.launchError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

/// A titled, rounded group of rows.
private struct Card<Content: View>: View {
    let title: String
    var controlSize: ControlSize = .regular
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .controlSize(controlSize)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        }
    }
}

/// "Label ……… value" row with a fixed label column.
private struct InfoRow<Value: View>: View {
    let label: String
    @ViewBuilder var value: Value

    init(_ label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            value
            Spacer(minLength: 0)
        }
        .font(.subheadline)
    }
}
