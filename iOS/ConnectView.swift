import SwiftUI

struct ConnectView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var updater: AppUpdater
    @Environment(\.openURL) private var openURL

    @State private var manualAddress = ""
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                if let version = updater.bannerVersion {
                    updateBanner(version)
                }

                Section {
                    if app.browser.hosts.isEmpty {
                        HStack(spacing: 10) {
                            if app.browser.isSearching {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Searching for Macs on your network…")
                            } else {
                                Image(systemName: "desktopcomputer.trianglebadge.exclamationmark")
                                    .foregroundStyle(.secondary)
                                Text("No Macs found nearby.")
                            }
                        }
                        .foregroundStyle(.secondary)
                    } else {
                        ForEach(app.browser.hosts) { host in
                            Button {
                                app.connect(to: host)
                            } label: {
                                row(name: host.name, trusted: app.isPaired(host.serverId))
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Nearby Macs")
                        Spacer()
                        if app.browser.isSearching && !app.browser.hosts.isEmpty {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                }

                if !app.recents.isEmpty {
                    Section("Recents") {
                        ForEach(app.recents) { recent in
                            Button {
                                app.connectRecent(recent)
                            } label: {
                                row(name: recent.name, trusted: app.isPaired(recent.serverId))
                            }
                        }
                        .onDelete { indexSet in
                            app.deleteRecent(at: indexSet)
                        }
                    }
                }

                Section {
                    HStack {
                        TextField("192.168.1.20:52341", text: $manualAddress)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("Connect") {
                            app.connectManual(manualAddress)
                        }
                        .disabled(manualAddress.isEmpty)
                    }
                    if let error = app.manualError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Connect manually")
                } footer: {
                    Text("Start sharing on the Mac (menu bar icon) and use the address shown there.")
                }
            }
            .refreshable {
                app.browser.restart()
            }
            .navigationTitle("LocalDesktop")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(app)
                .environmentObject(updater)
        }
        .fullScreenCover(item: $app.session, onDismiss: {
            app.endSession()
        }) { session in
            SessionView(session: session, app: app, onDismiss: {
                app.endSession()
            })
        }
    }

    private func updateBanner(_ version: String) -> some View {
        let awaiting = updater.isAwaitingInstall
        return Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: awaiting ? "arrow.down.to.line" : "arrow.down")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(awaiting ? "Almost done" : "Update available")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                        Text("LocalDesktop \(version)")
                            .font(.headline)
                        Text(awaiting
                             ? "After tapping Install, close the app. It updates on the Home Screen."
                             : "Your paired Macs and settings are kept.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button {
                        if awaiting {
                            updater.endInstall()
                        } else {
                            updater.dismissBanner()
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(awaiting ? "Cancel" : "Not now")
                }

                HStack(spacing: 10) {
                    if awaiting {
                        Button {
                            updater.closeAppToFinishInstall()
                        } label: {
                            Text("Close App").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            installUpdate()
                        } label: {
                            Text("Install").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        if let notes = updater.releaseNotesURL(for: version) {
                            Button {
                                openURL(notes)
                            } label: {
                                Text("What's New").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .controlSize(.large)
                .fontWeight(.semibold)
            }
            .padding(.vertical, 6)
            .animation(.default, value: awaiting)
        }
    }

    private func installUpdate() {
        guard let url = updater.beginInstall() else { return }
        openURL(url) { accepted in
            if !accepted { updater.endInstall() }
        }
    }

    private func row(name: String, trusted: Bool) -> some View {
        HStack {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(.tint)
            Text(name)
            Spacer()
            if trusted {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
        }
    }
}
