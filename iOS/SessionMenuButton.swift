import SwiftUI

struct SessionMenuButton: View {
    @Binding var touchpadMode: Bool
    @ObservedObject var app: AppModel
    let session: ClientSession
    /// Passed in rather than read from `session`, which this view doesn't observe.
    let displays: [RDDisplay]
    let selectedDisplayId: UInt32?
    let blocksMacInput: Bool?
    @ObservedObject var canvasController: CanvasController
    let onDismiss: () -> Void
    @State private var showHardwareSheet = false

    var body: some View {
        Menu {
            Button {
                showHardwareSheet = true
            } label: {
                Label("Mac Hardware Controls…", systemImage: "slider.horizontal.3")
            }

            if let blocksMacInput {
                Toggle(isOn: Binding(get: { blocksMacInput }, set: { session.setBlocksMacInput($0) })) {
                    Label("Block Mac's Keyboard & Trackpad", systemImage: "lock.display")
                }
            }

            // Empty with a Mac older than 1.2.1, which doesn't send its displays.
            if !displays.isEmpty {
                Menu {
                    ForEach(displays) { display in
                        Button {
                            session.selectDisplay(display.id)
                        } label: {
                            if display.id == selectedDisplayId {
                                Label("\(display.name) · \(display.resolution)", systemImage: "checkmark")
                            } else {
                                Text("\(display.name) · \(display.resolution)")
                            }
                        }
                    }
                    if displays.count == 1 {
                        Section {
                            Text("Connect another display to the Mac to switch between them.")
                        }
                    }
                } label: {
                    let current = displays.first { $0.id == selectedDisplayId }
                    Label("Display: \(current?.name ?? "Choose")",
                          systemImage: displays.count > 1 ? "display.2" : "display")
                }
            }

            Button {
                withAnimation {
                    session.showDebugHUD.toggle()
                }
            } label: {
                Label(session.showDebugHUD ? "Hide Performance HUD" : "Show Performance HUD",
                      systemImage: "chart.xyaxis.line")
            }

            Divider()

            Button {
                touchpadMode.toggle()
            } label: {
                Label(touchpadMode ? "Direct Mode" : "Touchpad Mode",
                      systemImage: touchpadMode ? "hand.tap" : "rectangle.on.rectangle")
            }

            Menu {
                let speeds: [(label: String, value: Double)] = [("Slow", 1.0), ("Normal", 1.5), ("Fast", 2.0)]
                ForEach(speeds, id: \.value) { speed in
                    Button {
                        app.settings.pointerSpeedMultiplier = speed.value
                    } label: {
                        if app.settings.pointerSpeedMultiplier == speed.value {
                            Label(speed.label, systemImage: "checkmark")
                        } else {
                            Text(speed.label)
                        }
                    }
                }
            } label: {
                let currentSpeedLabel = app.settings.pointerSpeedMultiplier == 2.0 ? "Fast" : (app.settings.pointerSpeedMultiplier == 1.5 ? "Normal" : "Slow")
                Label("Pointer Speed: \(currentSpeedLabel)", systemImage: "cursorarrow.motionlines")
            }

            Button {
                app.settings.showScrollHelpers.toggle()
            } label: {
                Label(app.settings.showScrollHelpers ? "Hide Scroll Helpers" : "Show Scroll Helpers", systemImage: "arrow.up.and.down")
            }

            Divider()

            Menu {
                ForEach(RDQualityPreset.allCases) { preset in
                    Button {
                        app.settings.qualityRaw = preset.rawValue
                        app.applyQualitySettings()
                    } label: {
                        if app.settings.qualityRaw == preset.rawValue {
                            Label(preset.label, systemImage: "checkmark")
                        } else {
                            Text(preset.label)
                        }
                    }
                }
            } label: {
                Label("Quality: \(app.settings.preset.shortLabel)", systemImage: "sparkles")
            }

            Menu {
                ForEach(RDCodec.allCases) { codec in
                    Button {
                        app.settings.codecRaw = codec.rawValue
                        app.applyQualitySettings()
                    } label: {
                        if app.settings.codecRaw == codec.rawValue {
                            Label(codec.label, systemImage: "checkmark")
                        } else {
                            Text(codec.label)
                        }
                    }
                }
            } label: {
                Label("Codec: \(app.settings.codec.label)", systemImage: "film")
            }

            if canvasController.isPiPSupported {
                Menu {
                    Button {
                        canvasController.togglePiP()
                    } label: {
                        Label(canvasController.isPiPActive ? "Exit Picture in Picture" : "Picture in Picture",
                              systemImage: canvasController.isPiPActive ? "pip.exit" : "pip.enter")
                    }
                    Button {
                        canvasController.isAutoPiPEnabled.toggle()
                    } label: {
                        if canvasController.isAutoPiPEnabled {
                            Label("Auto PiP: ON", systemImage: "checkmark")
                        } else {
                            Text("Auto PiP: OFF")
                        }
                    }
                } label: {
                    Label("Picture in Picture", systemImage: "pip")
                }
            }

            Button {
                session.requestKeyframe(reason: "user_refresh")
            } label: {
                Label("Refresh Video", systemImage: "arrow.triangle.2.circlepath")
            }

            Divider()

            Button(role: .destructive) {
                onDismiss()
            } label: {
                Label("Disconnect", systemImage: "xmark.circle")
            }
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.title2)
                .frame(width: 50, height: 50)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 0.5))
                .foregroundStyle(.white)
                .shadow(radius: 4)
        }
        .sheet(isPresented: $showHardwareSheet) {
            MacHardwareControlsSheet(session: session, isPresented: $showHardwareSheet)
        }
    }
}
