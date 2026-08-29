import SwiftUI

struct ConnectView: View {
    @EnvironmentObject private var app: AppModel

    @State private var manualAddress = ""
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
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
                                app.connect(endpoint: host.endpoint, fallbackName: host.name)
                            } label: {
                                row(name: host.name, trusted: isTrusted(host))
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
                                row(name: recent.name,
                                    trusted: TrustStore.token(serverId: recent.serverId) != nil)
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
            .navigationTitle("Local Desktop")
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
        }
        .fullScreenCover(item: $app.session, onDismiss: {
            app.endSession()
        }) { session in
            SessionView(session: session, app: app, onDismiss: {
                app.endSession()
            })
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

    private func isTrusted(_ host: DiscoveredHost) -> Bool {
        app.recents.contains { recent in
            host.name.hasPrefix(recent.name) && TrustStore.token(serverId: recent.serverId) != nil
        }
    }
}
