import SwiftUI

struct DebugHUDView: View {
    @ObservedObject var session: ClientSession

    var body: some View {
        HStack(spacing: 12) {
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
                Text(String(format: "%.1fms", session.currentRTT))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(session.currentRTT < 20 ? .green : (session.currentRTT < 50 ? .yellow : .red))
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
        .shadow(radius: 6)
    }
}
