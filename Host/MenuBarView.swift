import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject private var server: HostServer
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var launchManager: LaunchManager

    @State private var newPIN = ""
    @State private var changePIN = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: server.running ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.running ? "Sharing enabled" : "Sharing stopped")
                            .font(.headline)
                        if server.running {
                            Text(server.clientName.map { "Controlled by \($0)" } ?? "Waiting for a device…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(server.running ? "Stop" : "Start Sharing") {
                        server.toggle()
                    }
                    .controlSize(.large)
                    .disabled(!server.running && !(auth.hasPIN && server.screenGranted && server.accessibilityGranted))
                }
                if server.running, server.port > 0 {
                    LabeledContent("Address") {
                        Text("\(HostServer.primaryLANAddress().map { "\($0):" } ?? "")\(String(server.port))")
                            .font(.system(.body, design: .monospaced))
                    }
                    LabeledContent("Bonjour") {
                        Text(server.bonjourName)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Status")
            }

            if !auth.hasPIN {
                Section {
                    SecureField("4-digit PIN", text: $newPIN)
                        .textFieldStyle(.roundedBorder)
                    Button("Set PIN & Enable Sharing") {
                        guard isValidPIN(newPIN) else { return }
                        auth.setPIN(newPIN)
                        newPIN = ""
                        server.start()
                    }
                    .disabled(!isValidPIN(newPIN))
                } header: {
                    Text("Create access PIN")
                } footer: {
                    Text("Devices on this network must enter this 4-digit PIN the first time they connect. After that they can be trusted to skip the PIN.")
                }
            }

            if server.running {
                Section {
                    Picker("Quality", selection: Binding(
                        get: { server.preset },
                        set: { server.setPreset($0) }
                    )) {
                        ForEach(RDQualityPreset.allCases) { preset in
                            Text(preset.label).tag(preset)
                        }
                    }
                    Picker("Codec", selection: Binding(
                        get: { ScreenStreamer.shared.currentCodec },
                        set: { codec in
                            Task {
                                await ScreenStreamer.shared.updateConfiguration(preset: server.preset, codec: codec)
                            }
                        }
                    )) {
                        ForEach(RDCodec.allCases.filter { $0 != .jpeg }) { codec in
                            Text(codec.label).tag(codec)
                        }
                    }
                    if !server.displays.isEmpty {
                        Picker("Share display", selection: Binding(
                            get: { server.selectedDisplayID ?? server.displays.first?.id ?? CGMainDisplayID() },
                            set: { server.setDisplay($0) }
                        )) {
                            ForEach(Array(server.displays.enumerated()), id: \.element.id) { index, display in
                                Text("Display \(index + 1) · \(display.label)").tag(display.id)
                            }
                        }
                    }
                } header: {
                    Text("Session")
                }
            }

            Section {
                if auth.devices.isEmpty {
                    Text("No trusted devices yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(auth.devices) { device in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                Text(device.trustedAt, style: .date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Revoke") {
                                auth.revoke(ids: [device.id])
                            }
                        }
                    }
                }
            } header: {
                Text("Trusted devices")
            } footer: {
                Text("Revoked devices must re-enter the PIN on their next connection.")
            }

            if auth.hasPIN {
                Section {
                    HStack {
                        SecureField("New PIN", text: $changePIN)
                            .textFieldStyle(.roundedBorder)
                        Button("Change") {
                            guard isValidPIN(changePIN) else { return }
                            auth.setPIN(changePIN)
                            changePIN = ""
                        }
                        .disabled(!isValidPIN(changePIN))
                    }
                } header: {
                    Text("Change PIN")
                }
            }

            Section {
                Toggle("Start automatically on restart", isOn: Binding(
                    get: { launchManager.isEnabled },
                    set: { launchManager.setLaunchOnRestart($0) }
                ))
                if launchManager.status == .requiresApproval {
                    Label("Approval required in macOS System Settings.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Button("Open Login Items Settings…") {
                        launchManager.openSystemSettings()
                    }
                }
                if let error = launchManager.lastError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            } header: {
                Text("General")
            } footer: {
                Text("Automatically launches Local Desktop Host when your Mac starts up or restarts.")
            }

            Section {
                if !server.screenGranted {
                    Label("Grant Screen Recording so clients can see this Mac.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("Open Screen Recording Settings…") {
                        Self.openPrivacyPane("Privacy_ScreenCapture")
                    }
                }
                if !server.accessibilityGranted {
                    Label("Grant Accessibility (Input Monitoring) so remote input works.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("Open Permission Settings…") {
                        _ = InputInjector.checkAccessibility(prompt: true)
                    }
                }
                if let error = server.lastError {
                    Text(error)
                        .foregroundStyle(.red)
                }
                Button("Quit Local Desktop") {
                    NSApplication.shared.terminate(nil)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } header: {
                Text("Permissions & more")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 600)
        .task {
            server.refreshPermissions()
            launchManager.refreshStatus()
            if server.screenGranted {
                server.refreshDisplays()
            }
        }
    }

    private func isValidPIN(_ pin: String) -> Bool {
        pin.count == 4 && pin.allSatisfy(\.isNumber)
    }

    private static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
