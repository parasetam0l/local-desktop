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
                                Text("Searching for Macs on your network")
                            } else {
                                Image(systemName: "desktopcomputer.trianglebadge.exclamationmark")
                                Text("No Macs found nearby")
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(SessionStyle.secondaryText)
                        .frame(minHeight: 46)
                        .listRowBackground(SessionStyle.raised)
                    } else {
                        ForEach(app.browser.hosts) { host in
                            Button {
                                app.connect(to: host)
                            } label: {
                                row(name: host.name,
                                    status: "Available now",
                                    trusted: app.isPaired(host.serverId))
                            }
                            .listRowBackground(SessionStyle.raised)
                        }
                    }
                } header: {
                    HStack {
                        sectionTitle("Nearby Macs")
                        Spacer()
                        if app.browser.isSearching && !app.browser.hosts.isEmpty {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                }

                if !app.recents.isEmpty {
                    Section {
                        ForEach(app.recents) { recent in
                            Button {
                                app.connectRecent(recent)
                            } label: {
                                row(name: recent.name,
                                    status: recentStatus(recent),
                                    trusted: app.isPaired(recent.serverId))
                            }
                            .listRowBackground(SessionStyle.raised)
                        }
                        .onDelete { indexSet in
                            app.deleteRecent(at: indexSet)
                        }
                    } header: {
                        sectionTitle("Recent")
                    } footer: {
                        sectionFooter("Swipe left on a Mac to remove it from this list.")
                    }
                }

                Section {
                    HStack(spacing: 10) {
                        TextField("192.168.1.20:52341", text: $manualAddress)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("Connect") {
                            app.connectManual(manualAddress)
                        }
                        .buttonStyle(SessionButtonStyle(compact: true))
                        .disabled(manualAddress.isEmpty)
                    }
                    .font(.subheadline)
                    .frame(minHeight: 46)
                    .listRowBackground(SessionStyle.raised)
                    if let error = app.manualError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(SessionStyle.danger)
                            .listRowBackground(SessionStyle.raised)
                    }
                } header: {
                    sectionTitle("Connect manually")
                } footer: {
                    sectionFooter("Start sharing on the Mac (menu bar icon) and use the address shown there.")
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(18)
            .scrollContentBackground(.hidden)
            .listRowSeparatorTint(SessionStyle.hairline)
            .refreshable {
                app.browser.restart()
            }
            .navigationTitle("LocalDesktop")
            .toolbarBackground(SessionStyle.panel, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sessionPage()
        }
        .tint(SessionStyle.accent)
        .preferredColorScheme(.dark)
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

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.medium))
            .foregroundStyle(SessionStyle.secondaryText)
            .textCase(nil)
    }

    private func sectionFooter(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(SessionStyle.secondaryText)
    }

    private func recentStatus(_ recent: RecentHost) -> String {
        let nearby = app.browser.hosts.contains { host in
            !recent.serverId.isEmpty && host.serverId == recent.serverId
        }
        if nearby { return "Available now" }
        return "Last used \(recent.lastUsed.formatted(.relative(presentation: .named)))"
    }

    private func updateBanner(_ version: String) -> some View {
        let awaiting = updater.isAwaitingInstall
        return Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: awaiting ? "arrow.down.to.line" : "arrow.down")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(SessionStyle.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(awaiting ? "Almost done" : "Update available")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SessionStyle.accent)
                        Text("LocalDesktop \(version)")
                            .font(.headline)
                        Text(awaiting
                             ? "After tapping Install, close the app. It updates on the Home Screen."
                             : "Your paired Macs and settings are kept.")
                            .font(.subheadline)
                            .foregroundStyle(SessionStyle.secondaryText)
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
                        Image(systemName: "xmark")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(SessionStyle.secondaryText)
                            .frame(width: 28, height: 28)
                            .background(SessionStyle.raised, in: Circle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(awaiting ? "Cancel" : "Not now")
                }

                HStack(spacing: 10) {
                    if awaiting {
                        Button {
                            updater.closeAppToFinishInstall()
                        } label: {
                            Text("Close app")
                        }
                        .buttonStyle(SessionButtonStyle(prominent: true, fullWidth: true))
                    } else {
                        Button {
                            installUpdate()
                        } label: {
                            Text("Install")
                        }
                        .buttonStyle(SessionButtonStyle(prominent: true, fullWidth: true))
                        if let notes = updater.releaseNotesURL(for: version) {
                            Button {
                                openURL(notes)
                            } label: {
                                Text("What's new")
                            }
                            .buttonStyle(SessionButtonStyle(fullWidth: true))
                        }
                    }
                }
            }
            .padding(.vertical, 6)
            .animation(.default, value: awaiting)
            .listRowBackground(SessionStyle.raised)
        }
    }

    private func installUpdate() {
        guard let url = updater.beginInstall() else { return }
        openURL(url) { accepted in
            if !accepted { updater.endInstall() }
        }
    }

    private func row(name: String, status: String, trusted: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.body)
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(SessionStyle.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(status)
                    if trusted {
                        Text("·")
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(SessionStyle.accent)
                        Text("Paired")
                    }
                }
                .font(.caption)
                .foregroundStyle(SessionStyle.secondaryText)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("Connect")
                .font(.footnote.weight(.medium))
                .foregroundStyle(SessionStyle.accent)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(SessionStyle.secondaryText)
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Connects to this Mac")
    }
}
