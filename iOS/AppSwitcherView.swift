import SwiftUI

struct AppSwitcherButton: View {
    @ObservedObject var session: ClientSession
    @State private var showSheet = false

    var body: some View {
        Button {
            showSheet = true
        } label: {
            Image(systemName: "square.stack.3d.up")
                .font(.title2)
                .frame(width: 50, height: 50)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 0.5))
                .foregroundStyle(.white)
                .shadow(radius: 4)
        }
        .sheet(isPresented: $showSheet) {
            AppSwitcherView(session: session, isPresented: $showSheet)
        }
    }
}

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
        NavigationStack {
            VStack(spacing: 0) {
                // Quick Action Bar
                HStack(spacing: 12) {
                    Button {
                        session.triggerSystemAction(.showDesktop)
                        isPresented = false
                    } label: {
                        Label("Show Desktop", systemImage: "macwindow.on.rectangle")
                            .font(.caption.weight(.medium))
                    }
                    .glassButton(variant: .secondary, size: .small)

                    Button {
                        session.triggerSystemAction(.missionControl)
                        isPresented = false
                    } label: {
                        Label("Mission Control", systemImage: "square.grid.2x2")
                            .font(.caption.weight(.medium))
                    }
                    .glassButton(variant: .secondary, size: .small)

                    Spacer()

                    Button {
                        session.requestRunningApps()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.subheadline)
                    }
                    .glassButton(variant: .secondary, size: .small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()

                if session.runningApps.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Querying open applications on Mac...")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(filteredApps) { app in
                                Button {
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    session.activateApp(bundleId: app.bundleId)
                                    isPresented = false
                                } label: {
                                    HStack(spacing: 14) {
                                        // Real Native App Icon
                                        if let iconData = app.iconPNG.flatMap({ Data(base64Encoded: $0) }),
                                           let uiImage = UIImage(data: iconData) {
                                            Image(uiImage: uiImage)
                                                .resizable()
                                                .aspectRatio(contentMode: .fit)
                                                .frame(width: 44, height: 44)
                                                .cornerRadius(10)
                                                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                                        } else {
                                            Image(systemName: "app.fill")
                                                .font(.title2)
                                                .frame(width: 44, height: 44)
                                                .background(Color.secondary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
                                                .foregroundStyle(.primary)
                                        }

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(app.name)
                                                .font(.body.weight(.medium))
                                                .foregroundStyle(.primary)
                                            if app.isActive {
                                                Text("Active Window")
                                                    .font(.caption2.weight(.semibold))
                                                    .foregroundStyle(.green)
                                            } else if app.isHidden {
                                                Text("Hidden")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }

                                        Spacer()

                                        if app.isActive {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.green)
                                                .font(.title3)
                                        }
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(app.isActive ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search open apps")
                }
            }
            .navigationTitle("Mac App Switcher")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        isPresented = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
        .onAppear {
            session.requestRunningApps()
        }
    }
}
