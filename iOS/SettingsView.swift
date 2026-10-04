import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var updater: AppUpdater
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

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

                Section {
                    LabeledContent("Version", value: AppUpdater.currentVersion)
                    if let version = updater.availableVersion {
                        Button("Install LocalDesktop \(version)") {
                            if let url = updater.installURL { openURL(url) }
                        }
                    }
                    Button {
                        Task { await updater.check() }
                    } label: {
                        HStack {
                            Text("Check for Updates")
                            if updater.isChecking {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(updater.isChecking)
                } header: {
                    Text("Updates")
                } footer: {
                    Text(updateStatus)
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
