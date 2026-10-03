import SwiftUI

/// What the setup assistant needs from the rest of the app. Injected so the
/// assistant can be shown (and previewed) without touching the live services.
struct SetupEnvironment {
    var isGranted: @MainActor (PermissionKind) -> Bool
    var request: @MainActor (PermissionKind) -> Void
    var openSettings: @MainActor (PermissionKind) -> Void
    var reset: @MainActor (PermissionKind) async -> Void
    var relaunch: @MainActor () -> Void
    var hasPIN: @MainActor () -> Bool
    var setPIN: @MainActor (String) async -> Void
    var fingerprint: String
    var computerName: String
    var launchAtLogin: @MainActor () -> Bool
    var setLaunchAtLogin: @MainActor (Bool) -> Void
    var startSharing: @MainActor () -> Void
}

@MainActor
final class SetupModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case welcome
        case screenRecording
        case accessibility
        case pin
        case ready
    }

    @Published var step: Step
    @Published private(set) var granted: [PermissionKind: Bool] = [:]
    @Published private(set) var hasPIN = false
    @Published var launchAtLogin = false
    /// Permissions whose System Settings pane the user already visited from here;
    /// once set, the step offers the reset / relaunch fallbacks.
    @Published private(set) var visitedSettings: Set<PermissionKind> = []
    @Published private(set) var resetting: PermissionKind?
    @Published var isEditingPIN = false
    @Published var pin = ""
    @Published var confirmPIN = ""
    @Published private(set) var isSavingPIN = false

    let environment: SetupEnvironment

    init(environment: SetupEnvironment, startAt: Step? = nil) {
        self.environment = environment
        self.step = .welcome
        refresh()
        launchAtLogin = environment.launchAtLogin()
        step = startAt ?? initialStep
    }

    /// Fresh installs start with the welcome page; otherwise jump to what's missing.
    private var initialStep: Step {
        let nothingDone = !hasPIN && !PermissionKind.allCases.contains { isGranted($0) }
        if nothingDone { return .welcome }
        if !isGranted(.screenRecording) { return .screenRecording }
        if !isGranted(.accessibility) { return .accessibility }
        if !hasPIN { return .pin }
        return .ready
    }

    func isGranted(_ kind: PermissionKind) -> Bool {
        granted[kind] ?? false
    }

    var missing: [String] {
        var items = PermissionKind.allCases.filter { !isGranted($0) }.map(\.title)
        if !hasPIN { items.append("PIN") }
        return items
    }

    var isComplete: Bool { missing.isEmpty }

    func refresh() {
        for kind in PermissionKind.allCases {
            let value = environment.isGranted(kind)
            if granted[kind] != value {
                granted[kind] = value
            }
        }
        let pinSet = environment.hasPIN()
        if hasPIN != pinSet {
            hasPIN = pinSet
        }
    }

    // MARK: Navigation

    func next() {
        guard let following = Step(rawValue: step.rawValue + 1) else { return }
        step = following
    }

    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    // MARK: Permissions

    /// The first time, macOS shows its own prompt (with a button into System
    /// Settings); after that it stays silent, so open the pane directly.
    func openSettings(for kind: PermissionKind) {
        if visitedSettings.contains(kind) {
            environment.openSettings(kind)
        } else {
            environment.request(kind)
            if kind == .accessibility {
                // The accessibility prompt is easy to miss behind other windows.
                environment.openSettings(kind)
            }
        }
        visitedSettings.insert(kind)
    }

    func resetEntry(for kind: PermissionKind) async {
        resetting = kind
        await environment.reset(kind)
        environment.request(kind)
        environment.openSettings(kind)
        resetting = nil
        refresh()
    }

    func relaunch() {
        environment.relaunch()
    }

    // MARK: PIN

    var pinValidationMessage: String? {
        if pin.isEmpty { return nil }
        if !PINHasher.isValidFormat(pin) { return "Use exactly 4 digits." }
        if !confirmPIN.isEmpty && confirmPIN != pin { return "The PINs don't match." }
        return nil
    }

    var canSavePIN: Bool {
        PINHasher.isValidFormat(pin) && pin == confirmPIN && !isSavingPIN
    }

    func savePIN() async {
        guard canSavePIN else { return }
        isSavingPIN = true
        await environment.setPIN(pin)
        isSavingPIN = false
        pin = ""
        confirmPIN = ""
        isEditingPIN = false
        refresh()
        next()
    }

    // MARK: Finish

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin = enabled
        environment.setLaunchAtLogin(enabled)
    }

    func startSharing() {
        environment.startSharing()
    }
}

// MARK: - Views

struct SetupAssistantView: View {
    @ObservedObject var model: SetupModel
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            StepIndicator(current: model.step)
                .padding(.top, 22)

            Group {
                switch model.step {
                case .welcome:
                    WelcomeStep(model: model)
                case .screenRecording:
                    PermissionStep(model: model, kind: .screenRecording)
                case .accessibility:
                    PermissionStep(model: model, kind: .accessibility)
                case .pin:
                    PINStep(model: model)
                case .ready:
                    ReadyStep(model: model)
                }
            }
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 18)

            Divider()
            bottomBar
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 560, height: 520)
        .task {
            // Permissions are granted in System Settings, so keep checking while open.
            while !Task.isCancelled {
                model.refresh()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        HStack {
            if model.step != .welcome {
                Button("Back") { model.back() }
            }
            Spacer()
            switch model.step {
            case .welcome:
                Button("Get Started") { model.next() }
                    .keyboardShortcut(.defaultAction)
            case .screenRecording, .accessibility:
                let kind: PermissionKind = model.step == .screenRecording ? .screenRecording : .accessibility
                if model.isGranted(kind) {
                    Button("Continue") { model.next() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Skip for Now") { model.next() }
                }
            case .pin:
                if model.hasPIN && !model.isEditingPIN {
                    Button("Continue") { model.next() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    if model.hasPIN {
                        Button("Cancel") {
                            model.isEditingPIN = false
                            model.pin = ""
                            model.confirmPIN = ""
                        }
                    }
                    Button(model.hasPIN ? "Save PIN" : "Set PIN") {
                        Task { await model.savePIN() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSavePIN)
                }
            case .ready:
                if model.isComplete {
                    Button("Start Sharing") {
                        model.startSharing()
                        onClose()
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Close") { onClose() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .controlSize(.large)
    }
}

/// Dots for the three setup tasks between the welcome and ready pages.
private struct StepIndicator: View {
    let current: SetupModel.Step

    var body: some View {
        HStack(spacing: 8) {
            ForEach(SetupModel.Step.allCases, id: \.rawValue) { step in
                Capsule()
                    .fill(step == current ? Color.accentColor : Color.primary.opacity(step.rawValue < current.rawValue ? 0.35 : 0.12))
                    .frame(width: step == current ? 22 : 8, height: 8)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current.rawValue + 1) of \(SetupModel.Step.allCases.count)")
    }
}

private struct StepHeader: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(title)
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct StatusPill: View {
    let isOn: Bool
    let onText: String
    let offText: String

    var body: some View {
        Label(isOn ? onText : offText, systemImage: isOn ? "checkmark.circle.fill" : "circle.dashed")
            .font(.callout.weight(.medium))
            .foregroundStyle(isOn ? Color.green : Color.orange)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background((isOn ? Color.green : Color.orange).opacity(0.14), in: Capsule())
            .animation(.default, value: isOn)
    }
}

private struct WelcomeStep: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(spacing: 22) {
            StepHeader(symbol: "macbook.and.iphone",
                       tint: .blue,
                       title: "Welcome to LocalDesktop",
                       message: "Control this Mac from your iPhone or iPad over your local network. Setup takes about a minute.")
            VStack(alignment: .leading, spacing: 12) {
                ChecklistRow(symbol: "rectangle.dashed.badge.record", title: "Allow Screen Recording",
                             detail: "So your iPhone can see this Mac's screen.", done: model.isGranted(.screenRecording))
                ChecklistRow(symbol: "accessibility", title: "Allow Accessibility",
                             detail: "So it can move the pointer, click, and type.", done: model.isGranted(.accessibility))
                ChecklistRow(symbol: "lock.shield", title: "Choose a PIN",
                             detail: "So only your devices can connect.", done: model.hasPIN)
            }
            .padding(16)
            .frame(maxWidth: 380, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

private struct ChecklistRow: View {
    let symbol: String
    let title: String
    let detail: String
    let done: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }
}

private struct PermissionStep: View {
    @ObservedObject var model: SetupModel
    let kind: PermissionKind

    private var granted: Bool { model.isGranted(kind) }

    private var symbol: String {
        kind == .screenRecording ? "rectangle.dashed.badge.record" : "accessibility"
    }

    private var message: String {
        switch kind {
        case .screenRecording:
            return "LocalDesktop streams this Mac's screen to your paired devices, encrypted. Nothing is recorded or stored."
        case .accessibility:
            return "This lets your iPhone move the pointer, click, scroll, and type on this Mac."
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            StepHeader(symbol: symbol, tint: kind == .screenRecording ? .pink : .indigo,
                       title: "Allow \(kind.title)", message: message)
            StatusPill(isOn: granted, onText: "Allowed", offText: "Not allowed yet")
                .onChange(of: granted) { _, nowGranted in
                    // Move on by itself once System Settings has done its part.
                    guard nowGranted else { return }
                    let step = model.step
                    Task {
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        if model.step == step {
                            model.next()
                        }
                    }
                }

            if !granted {
                VStack(alignment: .leading, spacing: 6) {
                    instruction(1, "Click **Open System Settings**.")
                    instruction(2, "Turn on **LocalDesktop** in the list.")
                    if kind == .screenRecording {
                        instruction(3, "If macOS asks, choose **Quit & Reopen**. Setup continues where you left off.")
                    }
                }
                .frame(maxWidth: 400, alignment: .leading)

                Button("Open System Settings") {
                    model.openSettings(for: kind)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if model.visitedSettings.contains(kind) {
                    troubleshooting
                }
            }
        }
    }

    private func instruction(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.secondary))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var troubleshooting: some View {
        VStack(spacing: 6) {
            Text("Already switched on but still not detected? After an update, macOS can keep an outdated entry.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    Task { await model.resetEntry(for: kind) }
                } label: {
                    if model.resetting == kind {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Reset Entry")
                    }
                }
                .disabled(model.resetting != nil)
                if kind == .screenRecording {
                    Button("Relaunch App") { model.relaunch() }
                }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: 420)
    }
}

private struct PINStep: View {
    @ObservedObject var model: SetupModel
    @FocusState private var focusedField: Field?

    private enum Field {
        case pin
        case confirm
    }

    var body: some View {
        VStack(spacing: 16) {
            StepHeader(symbol: "lock.shield.fill", tint: .green,
                       title: model.hasPIN && !model.isEditingPIN ? "Your PIN Is Set" : "Choose a PIN",
                       message: "Your iPhone or iPad asks for this 4-digit PIN the first time it connects. After that it's remembered, and you can revoke it from the menu bar at any time.")

            if model.hasPIN && !model.isEditingPIN {
                StatusPill(isOn: true, onText: "PIN set", offText: "")
                Button("Change PIN…") {
                    model.isEditingPIN = true
                    focusedField = .pin
                }
            } else {
                VStack(spacing: 10) {
                    SecureField("4-digit PIN", text: $model.pin)
                        .focused($focusedField, equals: .pin)
                        .onSubmit { focusedField = .confirm }
                    SecureField("Confirm PIN", text: $model.confirmPIN)
                        .focused($focusedField, equals: .confirm)
                        .onSubmit { Task { await model.savePIN() } }
                    Text(model.pinValidationMessage ?? " ")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                .textFieldStyle(.roundedBorder)
                .font(.title3.monospacedDigit())
                .frame(width: 220)
                .onAppear { focusedField = .pin }
            }
        }
    }
}

private struct ReadyStep: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(spacing: 16) {
            if model.isComplete {
                StepHeader(symbol: "checkmark.seal.fill", tint: .green,
                           title: "You're All Set",
                           message: "On your iPhone or iPad, open Local Desktop, tap \(model.environment.computerName), and enter your PIN.")
            } else {
                StepHeader(symbol: "exclamationmark.triangle.fill", tint: .orange,
                           title: "Almost There",
                           message: "Sharing can start once these are done: \(model.missing.joined(separator: ", ")). Go back, or finish later from the menu bar.")
            }

            VStack(spacing: 6) {
                Text("Your iPhone shows this fingerprint when pairing. Only enter the PIN if they match.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.environment.fingerprint)
                    .font(.title3.monospaced().weight(.semibold))
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .frame(maxWidth: 420)

            Toggle("Open LocalDesktop at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.checkbox)

            if model.isComplete {
                Label("If macOS asks to find devices on your local network, click Allow.", systemImage: "network")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Window

/// Shows the setup assistant in its own window (the app otherwise only has a menu bar panel).
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    static let shared = SetupWindowController()

    private var window: NSWindow?

    func show(startAt step: SetupModel.Step? = nil) {
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = SetupModel(environment: .live, startAt: step)
        let view = SetupAssistantView(model: model) { [weak self] in
            self?.window?.close()
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "LocalDesktop Setup"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        HostServer.shared.refreshPermissions()
    }
}

extension SetupEnvironment {
    /// The real services.
    @MainActor
    static var live: SetupEnvironment {
        SetupEnvironment(
            isGranted: { Permissions.isGranted($0) },
            request: { Permissions.request($0) },
            openSettings: { Permissions.openSettings($0) },
            reset: { await Permissions.reset($0) },
            relaunch: { Permissions.relaunch() },
            hasPIN: { AuthStore.shared.hasPIN },
            setPIN: { await AuthStore.shared.setPIN($0) },
            fingerprint: AuthStore.shared.identityFingerprint,
            computerName: HostServer.computerName,
            launchAtLogin: { LaunchManager.shared.isEnabled },
            setLaunchAtLogin: { LaunchManager.shared.setLaunchOnRestart($0) },
            startSharing: {
                HostServer.shared.refreshPermissions()
                HostServer.shared.start()
            }
        )
    }
}
