import SwiftUI

struct MacHardwareControlsSheet: View {
    @ObservedObject var session: ClientSession
    @Binding var isPresented: Bool

    @State private var localBrightness: Float = 0.5
    @State private var isDraggingBrightness = false
    @State private var localVolume: Double = 50
    @State private var isDraggingVolume = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Brightness and volume")
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

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PanelSection("Display") {
                        PanelRow {
                            Text("Brightness")
                            Spacer(minLength: 12)
                            Text("\(Int(localBrightness * 100))%")
                                .monospacedDigit()
                                .foregroundStyle(SessionStyle.secondaryText)
                        }
                        PanelRow {
                            Image(systemName: "sun.min")
                                .foregroundStyle(SessionStyle.secondaryText)
                            Slider(
                                value: $localBrightness,
                                in: 0...1,
                                onEditingChanged: { editing in
                                    isDraggingBrightness = editing
                                    if !editing {
                                        session.setBrightness(localBrightness)
                                    }
                                }
                            )
                            Image(systemName: "sun.max.fill")
                                .foregroundStyle(SessionStyle.secondaryText)
                        }
                    }

                    PanelSection("Sound") {
                        PanelRow {
                            Text("Volume")
                            Spacer(minLength: 12)
                            Text(session.hardwareControls.isMuted ? "Muted" : "\(Int(localVolume))%")
                                .monospacedDigit()
                                .foregroundStyle(session.hardwareControls.isMuted ? SessionStyle.danger : SessionStyle.secondaryText)
                        }
                        PanelRow {
                            Button {
                                session.setMuted(!session.hardwareControls.isMuted)
                            } label: {
                                Image(systemName: session.hardwareControls.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                    .foregroundStyle(session.hardwareControls.isMuted ? SessionStyle.danger : Color.white)
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(session.hardwareControls.isMuted ? "Unmute" : "Mute")

                            Slider(
                                value: $localVolume,
                                in: 0...100,
                                onEditingChanged: { editing in
                                    isDraggingVolume = editing
                                    if !editing {
                                        session.setVolume(Int(localVolume))
                                    }
                                }
                            )
                        }
                    }

                    PanelSection("Screen and power") {
                        PanelButtonRow(title: "Lock Mac screen", symbol: "lock.fill") {
                            session.lockHostScreen()
                            isPresented = false
                        }
                        PanelButtonRow(title: "Sleep Mac display", symbol: "moon.fill") {
                            session.sleepHostDisplay()
                        }
                        PanelButtonRow(title: "Wake Mac display", symbol: "sun.horizon.fill") {
                            session.wakeHostDisplay()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
        .sessionPage()
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .onAppear {
            localBrightness = session.hardwareControls.brightness
            localVolume = Double(session.hardwareControls.volume)
            session.requestHardwareControls()
        }
        .onChange(of: session.hardwareControls) { _, newControls in
            if !isDraggingBrightness {
                localBrightness = newControls.brightness
            }
            if !isDraggingVolume {
                localVolume = Double(newControls.volume)
            }
        }
    }
}
