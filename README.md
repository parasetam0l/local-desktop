# Local Desktop

A Swift-based local desktop for your local network:

- **`LocalDesktop` (macOS, menu bar app)** — shares the screen over the LAN and injects remote input.
- **`LocalDesktopClient` (iOS/iPadOS app)** — discovers Macs, connects, and controls them.

Both apps speak the same custom TCP protocol (see [`Protocol.md`](Protocol.md)) built on
`Network.framework`, `CryptoKit`, and Bonjour. No third-party dependencies.

## Features

- **Auto-discovery** — Macs advertise themselves via Bonjour (`_rd-desktop._tcp`); the iOS app lists them automatically.
- **Auto-connection** — optionally dials the last paired Mac on launch (as soon as it appears on the network) and reconnects after drops with exponential backoff (1 s → 30 s, giving up after 5 minutes). A Mac that stops sharing tells the client not to reconnect.
- **Hardware-Accelerated Video (HEVC & H.264)** — real-time hardware video compression via `VideoToolbox`, rendered with `AVSampleBufferDisplayLayer`.
- **Live Adaptive Bitrate (ABR) & Anti-Bufferbloat** — RTT telemetry scales the bitrate (to the slowest connected client) and stale P-frames are dropped instead of queued when Wi-Fi backs up.
- **Automatic Display Wake** — multi-vector background wake pulses wake sleeping displays immediately upon connection without manual interaction.
- **Wake-on-LAN** — tapping a recent Mac sends a magic packet first and keeps retrying for a minute while it wakes.
- **Mac identity pinning** — every Mac has a long-term Ed25519 identity. The iPhone pins it when pairing and refuses to talk to anything else claiming to be that Mac.
- **4-digit PIN pairing** — first connection requires the PIN set on the Mac. Wrong guesses lock PIN entry for everyone, with an escalating delay that survives restarts.
- **Trusted devices** — after pairing, the iPhone proves itself with its own key (kept in the Keychain), so later connections skip the PIN. The Mac shows trusted devices and can revoke them at any time.
- **Encryption** — every connection runs an X25519 key exchange; everything after the handshake is sealed with ChaCha20-Poly1305 with per-direction keys and replay protection.
- **Instant Cursor Prediction** — 0ms perceived pointer latency in touchpad and direct modes with local 120Hz display refresh tracking.
- **Zoom on mobile** — pinch to zoom (fit → 8×) and pan while zoomed.
- **Direct mode** — tap = left click, two-finger tap = right click, long-press = right click, tap-and-drag = press & drag.
- **Touchpad mode** — the whole screen becomes a trackpad: one-finger drag moves the pointer (with on-screen cursor), tap = click, two-finger tap = right click, two-finger drag = smooth scroll, pinch = zoom, tap-and-drag = click-drag.
- **Keyboard** — full system keyboard via a hidden capture field, plus a key bar with modifiers (⇧⌃⌥⌘: tap for the next key, double-tap to lock), Esc/Tab/arrows/Home/End/Page keys, so shortcuts like ⌘C work.
- **Quality presets** — Low (30 FPS), Balanced (60 FPS), High (60 FPS), and Sharp (Native 60 FPS) presets, switchable live from the client.
- **Crash recovery** — a small supervisor process relaunches the host if it crashes and restores the sharing state it had.
- **Setup Assistant** — walks through the Screen Recording and Accessibility permissions and the PIN on first launch, and whenever one goes missing.
- **Automatic updates** — the Mac app checks GitHub Releases once a day (Sparkle) and asks before installing a new version.

## Project layout

```
Shared/               Protocol, handshake & encryption, Bonjour browser (compiled into both apps)
Host/                 macOS host app: server, capture & encoding, input injection, PIN/trust store, menu bar UI
iOS/                  iOS client app: connection, decoding, discovery UI, zoom canvas, touchpad, keyboard, PIN pad
Tests/                Unit tests for the protocol, crypto, and PIN lockout (macOS test bundle)
Scripts/, Packaging/  Release helpers: notarization, DMG, Sparkle signing
.github/workflows/    Release and Appcast workflows (see docs/RELEASING.md)
project.yml           XcodeGen spec → generates LocalDesktop.xcodeproj
build.sh              Build / install / test script
Protocol.md           Wire protocol reference
```

## How to Build

Requirements: macOS 14+, iOS 17+, Xcode 16+ (Swift 6), and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

### Using build.sh (Recommended)

```sh
./build.sh                       # build Host and Client (Release)
./build.sh --install             # build, install Host to /Applications and Client to a connected iPhone
./build.sh --host --install      # just the Mac app
./build.sh --test                # run the unit tests
./build.sh --team ABCDE12345     # sign the iOS app with a different Apple Developer Team ID
```

Build products land in `build/` (ignored by git).

Signing (set in `project.yml`, team `P7V7795SS9`):

- **Mac host**: *Developer ID Application* certificate (the one valid until 2031, pinned by its SHA-1
  because an older certificate has the same name), with Hardened Runtime, so it can be notarized
  for use on other Macs. No provisioning profile is needed.
- **iOS client**: *Apple Development*, automatic signing with the team's wildcard profile. The first
  `./build.sh --install` with the iPhone connected registers it with the team.

To change the team permanently, edit `DEVELOPMENT_TEAM` (and the host's `CODE_SIGN_IDENTITY`) in
`project.yml`; `--team` / the `DEVELOPMENT_TEAM` environment variable only override the iOS build.

### Using Xcode

1. Generate the Xcode project: `xcodegen generate`
2. Open `LocalDesktop.xcodeproj`.
3. Run the **LocalDesktopHost** scheme on your Mac (it builds LocalDesktop.app).
4. Run the **LocalDesktopClient** scheme on your iPhone/iPad.
   *(For a physical device, select your development team in "Signing & Capabilities". The iOS simulator works too, but cannot reach Macs outside its host network.)*
5. Run the **LocalDesktopTests** scheme (⌘U) for the unit tests.

### macOS permissions (host, first run)

1. **Screen Recording** — prompted when sharing starts (ScreenCaptureKit). Grant it in *System Settings → Privacy & Security → Screen Recording*.
2. **Accessibility / Input Monitoring** — required to inject mouse/keyboard events. The menu bar UI shows a warning and a button to open the permission dialog until granted.
3. **Local Network** — macOS asks once when the listener starts.

macOS ties these permissions to the app's code signature: after signing with a different team
or certificate, remove the old entries and grant them again.

### iOS permission (client, first run)

- **Local Network** — iOS asks once when the app starts browsing. Needed for Bonjour discovery and connections.

## Using it

1. On the Mac: open the menu bar icon → set a **4-digit PIN** → **Start Sharing**. The menu shows the address/port, the advertised name, and the Mac's **fingerprint**.
2. On iPhone: your Mac appears under **Nearby Macs** → tap it → the PIN screen shows the Mac's fingerprint; check it matches the menu bar, then enter the PIN (leave "Trust this device" on) → connected.
3. Control with the mode you prefer:
   - **Direct mode**: pinch/zoom, tap, two-finger tap, tap-and-drag.
   - **Touchpad mode**: toggle in the session menu; the screen acts like a big trackpad with a virtual cursor.
   - **Keyboard**: tap the keyboard button; use the key bar for modifiers and special keys.
4. From then on, connecting to that Mac skips the PIN (trusted device).

### Upgrading from protocol v1

Version 2 changed the handshake, so update **both** apps. Devices paired with v1 must enter the
PIN once more; the old trust tokens are deleted automatically. A Mac's server id is now derived
from its identity key, so it shows up as a new entry in Recents.

### Tips & troubleshooting

- Nothing discovered? Make sure both devices are on the same Wi‑Fi/LAN, no "AP/client isolation" is enabled on the router, and Local Network permission was granted on both sides.
- Remote control does nothing? Grant Accessibility to the host app on the Mac.
- "This Mac's identity doesn't match"? The Mac's identity key changed (e.g. LocalDesktop was reset) or something else on the network is answering for it. If you reset the Mac yourself, tap **Forget & Pair Again**.
- "PIN entry locked"? Too many wrong PINs were entered. Wait, or press **Clear** next to the failed-attempts line in the Mac's menu.
- Wrong scroll direction on the Mac? Scroll deltas follow `Protocol.md` (`dy > 0` scrolls up); flip the sign in `InputInjector.scroll` if it feels inverted with your setup.
- To force the PIN again on a device, revoke it on the Mac (Trusted devices → Revoke).
- Wake-on-LAN from iOS: the broadcast packet needs the `com.apple.developer.networking.multicast` entitlement (granted by Apple on request). Without it, the app still sends the packet to the Mac's last known address, which works while the router remembers the Mac, or via a Bonjour Sleep Proxy (Apple TV / HomePod).

## Security notes

- The Mac proves its identity on every connection by signing the handshake with a long-term Ed25519 key (stored with `0600` permissions in `~/Library/Application Support/localdesktop.host/`). The iPhone pins that key when it pairs, so an impostor on the network can't collect the PIN or a trusted device's credentials from it.
- The very first pairing is trust-on-first-use, like SSH: compare the fingerprint shown on the iPhone with the one in the Mac's menu bar before entering the PIN.
- All traffic after the handshake is authenticated-encrypted with per-direction keys; replayed, reordered, or modified messages are rejected.
- Paired devices authenticate with a signature over the handshake; no reusable secret ever crosses the wire, and the Mac stores only their public keys.
- A 4-digit PIN has only 10,000 values, so the real protection against guessing is the online lockout (5 free attempts, then 30 s doubling up to 1 h, shared across connections and restarts). The PIN is stored as a PBKDF2-HMAC-SHA256 hash (300k iterations, random salt), but anyone who can read the Mac's preferences can still brute-force a 4-digit PIN offline.
- Revoking a device on the Mac immediately invalidates it.
- The design is LAN-oriented; it intentionally does not traverse NAT or relay through the internet.

## Releases and updates

Signed, notarized releases of the Mac app are built by GitHub Actions when started by hand (the **Release**
workflow), and installed copies update themselves from GitHub Releases. How to set it up and make a release:
[docs/RELEASING.md](docs/RELEASING.md).

## Regenerating the project after edits

Sources live outside the `.xcodeproj`; after adding/removing files run `xcodegen generate` again (`build.sh` does this for you).

## License

MIT; see [LICENSE](LICENSE). The Mac app bundles [Sparkle](https://github.com/sparkle-project/Sparkle), which is MIT-licensed as well.
