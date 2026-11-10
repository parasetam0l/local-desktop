import SwiftUI

struct AppSwitcherView: View {
    @ObservedObject var session: ClientSession
    @Binding var isPresented: Bool
    @State private var searchText = ""

    var filteredApps: [RDRunningApp] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return session.runningApps
        }
        return session.runningApps.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            HStack(spacing: 8) {
                Button {
                    session.triggerSystemAction(.showDesktop)
                    isPresented = false
                } label: {
                    Label("Show desktop", systemImage: "macwindow.on.rectangle")
                }
                .buttonStyle(SessionButtonStyle(compact: true))

                Button {
                    session.triggerSystemAction(.missionControl)
                    isPresented = false
                } label: {
                    Label("Mission Control", systemImage: "square.grid.2x2")
                }
                .buttonStyle(SessionButtonStyle(compact: true))

                Spacer()

                Button {
                    session.requestRunningApps()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(SessionButtonStyle(compact: true))
                .accessibilityLabel("Refresh")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            if session.runningApps.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Asking the Mac for its open apps")
                        .font(.footnote)
                        .foregroundStyle(SessionStyle.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                searchField
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredApps) { app in
                            appRow(app)
                            if app.id != filteredApps.last?.id {
                                Rectangle()
                                    .fill(SessionStyle.hairline)
                                    .frame(height: 0.5)
                                    .padding(.leading, 60)
                            }
                        }
                    }
                    .background(SessionStyle.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
            }
        }
        .sessionPage()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            session.requestRunningApps()
        }
    }

    private var header: some View {
        HStack {
            Text("Mac apps")
                .font(.headline)
            Spacer()
            Button("Done") {
                isPresented = false
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(SessionStyle.accent)
        }
        .padding(.horizontal, 18)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(SessionStyle.secondaryText)
            TextField("Search open apps", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(SessionStyle.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(SessionStyle.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func appRow(_ app: RDRunningApp) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            session.activateApp(bundleId: app.bundleId)
            isPresented = false
        } label: {
            HStack(spacing: 12) {
                if let iconData = app.iconPNG.flatMap({ Data(base64Encoded: $0) }),
                   let uiImage = UIImage(data: iconData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 34, height: 34)
                } else {
                    Image(systemName: "app.fill")
                        .font(.title3)
                        .frame(width: 34, height: 34)
                        .background(SessionStyle.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    if app.isActive {
                        Text("In front")
                            .font(.caption)
                            .foregroundStyle(SessionStyle.accent)
                    } else if app.isHidden {
                        Text("Hidden")
                            .font(.caption)
                            .foregroundStyle(SessionStyle.secondaryText)
                    }
                }

                Spacer(minLength: 8)

                if app.isActive {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SessionStyle.accent)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
