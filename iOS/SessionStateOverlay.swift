import SwiftUI

/// Connection-state overlays shown above the remote screen: connecting, PIN entry,
/// failure (with reconnect countdown), and the connected-but-not-showing states.
struct SessionStateOverlay: View {
    @ObservedObject var session: ClientSession
    @ObservedObject var app: AppModel
    var onDismiss: () -> Void
    /// The sleeping card waits for a stable state so transient sleep/wake chatter doesn't
    /// flash it on and off.
    @State private var showsDisplaySleeping = false

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
                .task(id: session.isDisplaySleeping) {
                    if session.isDisplaySleeping {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        guard !Task.isCancelled else { return }
                        showsDisplaySleeping = true
                    } else {
                        showsDisplaySleeping = false
                    }
                }
        default:
            EmptyView()
        }
    }

    private var connectingOverlay: some View {
        ZStack {
            Color.black.opacity(session.hasVideoFrame ? 0.4 : 0.65)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .frame(width: 52, height: 52)

                VStack(spacing: 6) {
                    Text(session.hasConnectedOnce ? "Reconnecting" : "Connecting")
                        .font(.subheadline)
                        .foregroundStyle(SessionStyle.secondaryText)
                    Text(session.displayName)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                }

                Button(role: .cancel) {
                    onDismiss()
                } label: {
                    Text("Cancel")
                }
                .buttonStyle(SessionButtonStyle(fullWidth: true))
                .simultaneousGesture(TapGesture().onEnded {
                    onDismiss()
                })
            }
            .padding(24)
            .frame(maxWidth: 300)
            .stateCard()
        }
    }

    private func failedOverlay(message: String, countdown: Int?) -> some View {
        ZStack {
            Color.black.opacity(session.hasVideoFrame ? 0.45 : 0.65)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: session.identityMismatchServerId != nil ? "exclamationmark.shield.fill" : "wifi.exclamationmark")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(SessionStyle.danger)
                    .frame(width: 52, height: 52)
                    .background(SessionStyle.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(spacing: 6) {
                    Text(message)
                        .font(.headline)
                        .multilineTextAlignment(.center)

                    if let countdown {
                        Text("Reconnecting in \(countdown) s")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(SessionStyle.secondaryText)
                    }
                }

                HStack(spacing: 12) {
                    if let staleServerId = session.identityMismatchServerId {
                        Button("Forget and pair again") {
                            app.forgetHost(serverId: staleServerId)
                            session.pairAgain()
                        }
                        .buttonStyle(SessionButtonStyle(prominent: true))
                    } else {
                        Button("Reconnect now") {
                            session.retryNow()
                        }
                        .buttonStyle(SessionButtonStyle(prominent: true))
                    }

                    Button("Close") {
                        onDismiss()
                    }
                    .buttonStyle(SessionButtonStyle())
                }
            }
            .padding(24)
            .frame(maxWidth: 340)
            .stateCard()
        }
    }

    @ViewBuilder
    private var connectedOverlay: some View {
        // The display can still wake with the lid shut when asked, so the card
        // only stays while the display is actually asleep.
        switch ClientWakePolicy.connectedOverlay(isHeadlessClosedLid: session.isHeadlessClosedLid,
                                                 isDisplaySleeping: session.isDisplaySleeping,
                                                 showsDisplaySleeping: showsDisplaySleeping,
                                                 hasVideoFrame: session.hasVideoFrame) {
        case .lidClosed:
            lidClosedOverlay
        case .sleeping:
            sleepingOverlay
        case .loading:
            loadingOverlay
        case .none:
            EmptyView()
        }
    }

    /// A shut lid with no external display: the Mac doesn't wake its screen on its own then
    /// (that only looped between wake and sleep), so an explicit connect or touch asks it to.
    private var lidClosedOverlay: some View {
        VStack(spacing: 14) {
            Image(systemName: "laptopcomputer.slash")
                .font(.system(size: 34))
                .foregroundStyle(session.isWakingDisplay ? SessionStyle.accent : SessionStyle.secondaryText)
            Text("Mac lid is closed")
                .font(.headline)
            Text(lidClosedSubtitle)
                .font(.caption)
                .foregroundStyle(SessionStyle.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            wakeButton
        }
        .padding(24)
        .frame(maxWidth: 320)
        .stateCard()
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .onTapGesture {
            session.wakeHostDisplay()
        }
    }

    private var lidClosedSubtitle: String {
        if session.isWakingDisplay {
            return "Trying to wake the Mac…"
        }
        if session.wakeTimedOut {
            return "The Mac stayed asleep with the lid closed. Try again, or open the lid or connect an external display."
        }
        return "The Mac's screen is asleep. Tap to try waking it, or open the lid or connect an external display."
    }

    private var sleepingOverlay: some View {
        VStack(spacing: 14) {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 36))
                .foregroundStyle(SessionStyle.accent)
            Text("Mac display is sleeping")
                .font(.headline)
            Text(session.isWakingDisplay ? "Trying to wake the screen…" : "Tap anywhere to wake the screen")
                .font(.caption)
                .foregroundStyle(SessionStyle.secondaryText)
                .multilineTextAlignment(.center)
            wakeButton
        }
        .padding(24)
        .frame(maxWidth: 320)
        .stateCard()
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .onTapGesture {
            session.wakeHostDisplay()
        }
    }

    private var wakeButton: some View {
        Button {
            session.wakeHostDisplay()
        } label: {
            if session.isWakingDisplay {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text("Waking…")
                }
            } else {
                Label("Wake display", systemImage: "sun.max.fill")
            }
        }
        .buttonStyle(SessionButtonStyle(prominent: true))
        .disabled(session.isWakingDisplay)
    }

    private var loadingOverlay: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text("Loading display")
                .font(.subheadline)
                .foregroundStyle(SessionStyle.secondaryText)
        }
        .padding(24)
        .stateCard()
    }
}

/// Banner shown while the Mac's screen is locked.
struct HostLockedBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.subheadline)
                .foregroundStyle(.yellow)
            Text("Mac is locked")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .sessionSurface(Capsule())
    }
}

private extension View {
    /// The solid card the connection states sit on.
    func stateCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return foregroundStyle(.white)
            .background(SessionStyle.panel, in: shape)
            .overlay(shape.strokeBorder(SessionStyle.hairline, lineWidth: 0.5))
    }
}
