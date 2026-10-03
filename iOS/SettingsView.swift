import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Auto-connect to latest connected Mac", isOn: $app.settings.autoConnect)
                    Toggle("Reconnect automatically on drops", isOn: $app.settings.autoReconnect)
                } header: {
                    Text("Connection")
                } footer: {
                    Text("When enabled, the app will automatically connect to the most recently connected Mac as soon as it is detected on the network.")
                }

                Section("Video & Streaming") {
                    Picker("Default Quality", selection: $app.settings.qualityRaw) {
                        ForEach(RDQualityPreset.allCases) { preset in
                            Text(preset.label).tag(preset.rawValue)
                        }
                    }
                    .onChange(of: app.settings.qualityRaw) {
                        app.applyQualitySettings()
                    }

                    Picker("Video Codec", selection: $app.settings.codecRaw) {
                        Text("HEVC / H.265 (Recommended)").tag(RDCodec.hevc.rawValue)
                        Text("H.264").tag(RDCodec.h264.rawValue)
                    }
                    .onChange(of: app.settings.codecRaw) {
                        app.applyQualitySettings()
                    }
                }

                Section("Input") {
                    Toggle("Start sessions in touchpad mode", isOn: $app.settings.defaultTouchpad)
                    Toggle("Show remote Mac cursor", isOn: $app.settings.showRemoteCursor)
                        .onChange(of: app.settings.showRemoteCursor) {
                            app.applyQualitySettings()
                        }
                    Picker("Pointer Speed", selection: $app.settings.pointerSpeedMultiplier) {
                        Text("Slow").tag(1.0)
                        Text("Normal").tag(1.5)
                        Text("Fast").tag(2.0)
                    }
                }

                Section {
                    if app.recents.isEmpty {
                        Text("No Macs yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(app.recents) { recent in
                            HStack {
                                Text(recent.name)
                                Spacer()
                                if app.isPaired(recent.serverId) {
                                    Image(systemName: "checkmark.seal.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                    }
                    Button("Forget all trusted Macs", role: .destructive) {
                        app.forgetAllHosts()
                    }
                } header: {
                    Text("Trusted Macs")
                } footer: {
                    Text("Forgetting a Mac here only removes its pairing from this device. Revoke access on the Mac itself to block this device.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                Button("Done") {
                    dismiss()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
