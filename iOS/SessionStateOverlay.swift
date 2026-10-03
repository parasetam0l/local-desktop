import SwiftUI

/// Connection-state overlays shown above the remote screen: connecting, PIN entry,
/// failure (with reconnect countdown), and the connected-but-not-showing states.
struct SessionStateOverlay: View {
    @ObservedObject var session: ClientSession
    @ObservedObject var app: AppModel
    var onDismiss: () -> Void

    var body: some View {
        switch session.phase {
        case .connecting, .negotiating:
            connectingOverlay
        case .needPin:
            ZStack {
                Color.black.opacity(0.65)
                    .ignoresSafeArea()

                PinSheet(serverName: session.displayName,
                         fingerprint: session.hostFingerprint,
                         errorText: session.pinError,
                         refreshToken: session.pinAttemptCounter,
                         onCancel: {
                    onDismiss()
                }) { pin, trust in
                    session.submitPIN(pin, trust: trust)
                }
            }
        case .failed(let message, let countdown):
            failedOverlay(message: message, countdown: countdown)
        case .connected:
            connectedOverlay
        default:
            EmptyView()
        }
    }

    private var connectingOverlay: some View {
        ZStack {
            Color.black.opacity(session.hasVideoFrame ? 0.4 : 0.65)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.18))
                        .frame(width: 64, height: 64)
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }

                VStack(spacing: 6) {
                    Text(session.hasConnectedOnce ? "Reconnecting" : "Connecting")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.65))
                    Text(session.displayName)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                }

                Button(role: .cancel) {
                    onDismiss()
                } label: {
                    Text("Cancel")
                }
                .glassButton(variant: .secondary, size: .regular, isFullWidth: true)
                .simultaneousGesture(TapGesture().onEnded {
                    onDismiss()
                })
            }
            .padding(28)
            .frame(maxWidth: 300)
            .glassCard(cornerRadius: 24, opacity: 0.15, shadowRadius: 24)
        }
    }

    private func failedOverlay(message: String, countdown: Int?) -> some View {
        ZStack {
            Color.black.opacity(session.hasVideoFrame ? 0.45 : 0.65)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.18))
                        .frame(width: 64, height: 64)
                    Image(systemName: session.identityMismatchServerId != nil ? "exclamationmark.shield.fill" : "wifi.exclamationmark")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.red)
                }

                VStack(spacing: 6) {
                    Text(message)
                        .font(.headline.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)

                    if let countdown {
                        Text("Reconnecting in \(countdown)s…")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }

                HStack(spacing: 12) {
                    if let staleServerId = session.identityMismatchServerId {
                        Button("Forget & Pair Again") {
                            app.forgetHost(serverId: staleServerId)
                            session.pairAgain()
                        }
                        .glassButton(variant: .primary, size: .regular)
                    } else {
                        Button("Reconnect Now") {
                            session.retryNow()
                        }
                        .glassButton(variant: .primary, size: .regular)
                    }

                    Button("Close") {
                        onDismiss()
                    }
                    .glassButton(variant: .secondary, size: .regular)
                }
            }
            .padding(28)
            .frame(maxWidth: 320)
            .glassCard(cornerRadius: 24, opacity: 0.15, shadowRadius: 24)
        }
    }

    @ViewBuilder
    private var connectedOverlay: some View {
        if session.isDisplaySleeping {
            VStack(spacing: 14) {
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.indigo)
                Text("Mac Display is Sleeping")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Tap anywhere to wake the screen")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                Button {
                    session.wakeHostDisplay()
                } label: {
                    Label("Wake Display", systemImage: "sun.max.fill")
                }
                .glassButton(variant: .primary, size: .regular)
            }
            .padding(28)
            .glassCard(cornerRadius: 24, opacity: 0.25, shadowRadius: 20)
            .contentShape(Rectangle())
            .onTapGesture {
                session.wakeHostDisplay()
            }
        } else if !session.hasVideoFrame {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text("Loading display…")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(24)
            .glassCard(cornerRadius: 20, opacity: 0.15, shadowRadius: 16)
        }
    }
}

/// Banner shown while the Mac's screen is locked.
struct HostLockedBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.subheadline)
                .foregroundStyle(.yellow)
            Text("Mac is Locked")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
        .shadow(radius: 6)
    }
}
