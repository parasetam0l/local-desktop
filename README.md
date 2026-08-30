# Local Desktop

A Swift-based local desktop for your local network:

- **`LocalDesktopHost` (macOS, menu bar app)** — shares the screen over the LAN and injects remote input.
- **`LocalDesktopClient` (iOS/iPadOS app)** — discovers Macs, connects, and controls them.

Both apps speak the same custom TCP protocol (see [`Protocol.md`](Protocol.md)) built on
`Network.framework`, `CryptoKit`, and Bonjour. No third-party dependencies.

## Features

- **Auto-discovery** — Macs advertise themselves via Bonjour (`_rd-desktop._tcp`); the iOS app lists them automatically.
- **Auto-connection** — the client dials the last *trusted* Mac on launch (or as soon as it appears on the network) and auto-reconnects with backoff when a session drops.
- **Hardware-Accelerated Video (HEVC & H.264)** — real-time sub-2ms hardware video compression via `VideoToolbox` with zero-copy GPU video rendering via `AVSampleBufferDisplayLayer`.
- **Live Adaptive Bitrate (ABR) & Anti-Bufferbloat** — real-time RTT telemetry dynamically scales bitrate and drops stale P-frames on Wi-Fi jitter to guarantee sub-10ms latency.
- **Automatic Display Wake** — multi-vector background wake pulses wake sleeping displays immediately upon connection without manual interaction.
- **4-digit PIN authentication** — first connection requires the PIN set on the Mac (PBKDF2-hashed at rest, encrypted in transit, 5-attempt limit).
- **Trusted devices** — after a successful PIN entry the device gets a 256-bit token stored in the iOS Keychain; later connections skip the PIN. The Mac shows trusted devices and can revoke them at any time.
- **Encryption** — every connection runs an X25519 key exchange; the PIN, tokens, video, and input are sealed with ChaCha20-Poly1305.
- **Instant Cursor Prediction** — 0ms perceived pointer latency in touchpad and direct modes with local 120Hz display refresh tracking.
- **Zoom on mobile** — pinch to zoom (fit → 8×), pan while zoomed, double-tap to toggle zoom.
- **Direct mode** — tap = left click, two-finger tap = right click, long-press drag = press & drag.
- **Touchpad mode** — the whole screen becomes a trackpad: one-finger drag moves the pointer (with on-screen cursor), tap = click, two-finger tap = right click, two-finger drag = scroll, long-press + drag = click-drag.
- **Keyboard** — full system keyboard via a hidden capture field, plus a bar with sticky modifiers (⇧⌃⌥⌘), Esc/Tab/arrows/Home/End/Page keys, so shortcuts like ⌘C work.
- **Quality presets** — Low (30 FPS), Balanced (60 FPS), High (60 FPS), and Sharp (Native 60 FPS) presets, switchable live from the client.

## Project layout

```
Shared/               Protocol, crypto, Bonjour browser (compiled into both apps)
Host/                 macOS host app: server, capture, input injection, PIN/trust store, menu bar UI
iOS/                  iOS client app: session, discovery UI, zoom canvas, touchpad, keyboard, PIN pad
project.yml           XcodeGen spec → generates LocalDesktop.xcodeproj
Protocol.md           Wire protocol reference
```

## How to Build

Requirements: macOS 14+, iOS 17+, Xcode 15+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

### Using Xcode (Recommended)

1. Generate the Xcode project:
   ```sh
   xcodegen generate
   ```
2. Open the generated project:
   ```sh
   open LocalDesktop.xcodeproj
   ```
3. Run the **LocalDesktopHost** scheme on your Mac.
4. Run the **LocalDesktopClient** scheme on your iPhone/iPad.
   *(Note: For a physical device, remember to select your development team in the "Signing & Capabilities" tab. The iOS simulator works too, but cannot reach Macs outside its host network).*

### Using Command Line (xcodebuild)

If you prefer building from the command line for production (Release):

1. Generate the project first:
   ```sh
   xcodegen generate
   ```
2. Build the macOS Host app:
   ```sh
   xcodebuild -project LocalDesktop.xcodeproj -scheme LocalDesktopHost -configuration Release build
   ```
3. Build the iOS Client app (requires setting up a valid signing identity):
   ```sh
   xcodebuild -project LocalDesktop.xcodeproj -scheme LocalDesktopClient -configuration Release -destination 'generic/platform=iOS' -allowProvisioningUpdates build
   ```

### macOS permissions (host, first run)

1. **Screen Recording** — prompted when sharing starts (ScreenCaptureKit). Grant it in *System Settings → Privacy & Security → Screen Recording*.
2. **Accessibility / Input Monitoring** — required to inject mouse/keyboard events. The menu bar UI shows a warning and a button to open the permission dialog until granted.
3. **Local Network** — macOS asks once when the listener starts.

### iOS permission (client, first run)

- **Local Network** — iOS asks once when the app starts browsing. Needed for Bonjour discovery and connections.

## Using it

1. On the Mac: open the menu bar icon → set a **4-digit PIN** → **Start Sharing**. The address/port and advertised name are shown in the menu.
2. On iPhone: your Mac appears under **Nearby Macs** → tap it → enter the 4-digit PIN (leave "Trust this device" on) → connected.
3. Control with the mode you prefer:
   - **Direct mode**: pinch/zoom, tap, two-finger tap, long-press drag.
   - **Touchpad mode**: toggle in the bottom bar; the screen acts like a big trackpad with a virtual cursor.
   - **Keyboard**: tap the keyboard button; use the key bar for modifiers and special keys.
4. From then on, opening the app auto-connects to that Mac with no PIN prompt (trusted device).

### Tips & troubleshooting

- Nothing discovered? Make sure both devices are on the same Wi‑Fi/LAN, no "AP/client isolation" is enabled on the router, and Local Network permission was granted on both sides.
- Remote control does nothing? Grant Accessibility to the host app on the Mac.
- Wrong scroll direction on the Mac? Scroll direction follows the sending convention in `Protocol.md` (`dy > 0` = toward document end); flip the sign in `Host/ClientSession.swift` (`scroll` case) if it feels inverted with your setup.
- To force the PIN again on a device, revoke it on the Mac (Trusted devices → Revoke).

## Security notes

- All traffic after the handshake is authenticated-encrypted per message; the PIN and trust token never travel in cleartext.
- The PIN is stretched with PBKDF2-HMAC-SHA256 (60k iterations, per-install random salt) so a stolen preferences file can't be brute-forced cheaply.
- Trust tokens are random 256-bit values; only their SHA-256 hashes are stored on the Mac, and the tokens live in the iOS Keychain.
- Revoking a device on the Mac immediately invalidates its token.
- The design is LAN-oriented; it intentionally does not traverse NAT or relay through the internet.

## Regenerating the project after edits

Sources live outside the `.xcodeproj`; after adding/removing files run `xcodegen generate` again.
