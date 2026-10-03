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
            // Clean Custom Header
            HStack {
                Text("Mac Hardware")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)

                Spacer()

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.secondary.opacity(0.18), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 16) {
                    // Brightness Control
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Display Brightness", systemImage: "sun.max.fill")
                                .font(.headline)
                            Spacer()
                            Text("\(Int(localBrightness * 100))%")
                                .font(.subheadline.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 12) {
                            Image(systemName: "sun.min")
                                .foregroundStyle(.secondary)
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
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                    .glassCard(cornerRadius: 16, opacity: 0.12)

                    // Volume Control
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("System Volume", systemImage: session.hardwareControls.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.headline)
                            Spacer()
                            Text(session.hardwareControls.isMuted ? "Muted" : "\(Int(localVolume))%")
                                .font(.subheadline.monospacedDigit().weight(.semibold))
                                .foregroundStyle(session.hardwareControls.isMuted ? .red : .secondary)
                        }

                        HStack(spacing: 12) {
                            Button {
                                session.setMuted(!session.hardwareControls.isMuted)
                            } label: {
                                Image(systemName: session.hardwareControls.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                    .foregroundStyle(session.hardwareControls.isMuted ? .red : .primary)
                                    .font(.title3)
                                    .frame(width: 32, height: 32)
                            }

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

                            Text("\(Int(localVolume))%")
                                .font(.caption.monospacedDigit())
                                .frame(width: 36, alignment: .trailing)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                    .glassCard(cornerRadius: 16, opacity: 0.12)

                    // Display & Power Actions
                    VStack(spacing: 12) {
                        Button {
                            session.lockHostScreen()
                            isPresented = false
                        } label: {
                            Label("Lock Mac Screen", systemImage: "lock.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .glassButton(variant: .secondary, size: .regular, isFullWidth: true)

                        Button {
                            session.sleepHostDisplay()
                        } label: {
                            Label("Sleep Mac Display", systemImage: "moon.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .glassButton(variant: .secondary, size: .regular, isFullWidth: true)

                        Button {
                            session.wakeHostDisplay()
                        } label: {
                            Label("Wake Mac Display", systemImage: "sun.horizon.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .glassButton(variant: .secondary, size: .regular, isFullWidth: true)
                    }
                    .padding(16)
                    .glassCard(cornerRadius: 16, opacity: 0.12)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
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
