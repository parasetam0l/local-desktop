import SwiftUI

struct DebugHUDView: View {
    @ObservedObject var session: ClientSession

    private var protocolColor: Color {
        switch session.transportProtocol {
        case "QUIC·S", "QUIC·D":
            return .green
        case "QUIC":
            return .yellow
        case "TCP":
            return .orange
        default:
            return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            // FPS
            HStack(spacing: 4) {
                Text("FPS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                // The Mac only sends frames when the screen changes, so a still screen reads 0.
                Text(String(format: "%.1f", session.liveFPS))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(session.liveFPS >= 55 || session.liveFPS == 0 ? .green : (session.liveFPS >= 30 ? .yellow : .red))
            }

            Divider()
                .frame(height: 12)

            // RTT / Ping
            HStack(spacing: 4) {
                Text("RTT")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 2) {
                    Text(String(format: "%.1fms", session.currentRTT))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(session.currentRTT < 20 ? .green : (session.currentRTT < 50 ? .yellow : .red))
                    if session.rawRTT - session.currentRTT >= 15 {
                        Text(String(format: "·%.0f", session.rawRTT))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()
                .frame(height: 12)

            // Bitrate
            HStack(spacing: 4) {
                Text("RATE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1fM", session.liveBitrateMbps))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
            }

            Divider()
                .frame(height: 12)

            // Decode Latency
            HStack(spacing: 4) {
                Text("DEC")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1fms", session.liveDecodeMs))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(session.liveDecodeMs < 8 ? .green : (session.liveDecodeMs < 16 ? .yellow : .red))
            }

            Divider()
                .frame(height: 12)

            // Transport Protocol
            HStack(spacing: 4) {
                Text("PROTO")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(session.transportProtocol.isEmpty ? "—" : session.transportProtocol)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(protocolColor)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .sessionSurface(Capsule())
        .environment(\.colorScheme, .dark)
    }
}
