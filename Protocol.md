# LocalDesktop wire protocol (v2)

TCP transport (Network.framework), default port 52341. Every message is framed as:

```
+--------------------+---------+---------------------------+
| u32 length (BE)    | u8 type | payload (`length` bytes)  |
+--------------------+---------+---------------------------+
```

Only `hello`, `serverHello`, and a version-rejecting `authFailed` are sent in the clear.
Every other message is encrypted (see [Encryption](#encryption)), so its payload is
`ciphertext || tag(16)`.

Plaintext payloads are JSON, except video frames: `[u16 width BE][u16 height BE][u8 codec][Annex-B data]`
with codec `1` = H.264 and `2` = HEVC (H.265).

Size limits: 16 KiB per message before authentication, 1 MiB client → host afterwards,
32 MiB host → client (video). Frames with an unknown type are decrypted and ignored, so
newer message types don't break older peers.

## Message types

| Type | Name                  | Direction | Body (JSON) |
|------|-----------------------|-----------|-------------|
| 0x01 | hello                 | C → S     | `{version, deviceId, deviceName, pubKey}` |
| 0x02 | serverHello           | S → C     | `{version, serverId, serverName, pubKey, identityKey, signature}` |
| 0x03 | authPin               | C → S 🔒  | `{pin, trust, deviceKey?}` |
| 0x04 | authDevice            | C → S 🔒  | `{signature}` |
| 0x05 | authOK                | S → C 🔒  | `{serverName, trusted, macAddress?}` |
| 0x06 | authFailed            | S → C 🔒  | `{reason, kind?, retryAfter?}` — kind: `incorrectPin`, `lockedOut`, `busy`, `untrusted`, `tooManyAttempts`, `unsupportedVersion` |
| 0x10 | frame                 | S → C 🔒  | binary (see above) |
| 0x11 | requestKeyframe       | C → S 🔒  | `{reason?}` |
| 0x12 | frameAck              | C → S 🔒  | binary `[count u32]` big-endian: the `frame` messages received on this connection so far, sent on receipt of each. A host that has seen one holds new frames while the oldest unconfirmed one is 120 ms old or 8 are unconfirmed, and sets the bitrate from the delivery times instead of `networkStats` (from 1.2.29) |
| 0x20 | mouseMoveAbs          | both 🔒   | `{x, y}` — frame pixel space; the host echoes the resulting cursor position |
| 0x21 | mouseMoveRel          | C → S 🔒  | `{dx, dy}` — screen points |
| 0x22 | mouseDown             | C → S 🔒  | `{button}` (0 left, 1 right) |
| 0x23 | mouseUp               | C → S 🔒  | `{button}` |
| 0x24 | scroll                | C → S 🔒  | `{dx, dy, precise?}` — lines, or points when `precise`; dy > 0 scrolls **up** (toward the start of the document) |
| 0x30 | keyEvent              | C → S 🔒  | `{code, down, flags}` — Mac virtual key code, flags = modifier bitmask (shift 1, ctrl 2, alt 4, cmd 8); pressing code 57 toggles Caps Lock |
| 0x31 | textEvent             | C → S 🔒  | `{s}` — unicode text |
| 0x40 | ping                  | C → S 🔒  | `{t}` |
| 0x41 | pong                  | S → C 🔒  | `{t}` |
| 0x42 | networkStats          | C → S 🔒  | `{rttMs, decodeMs, fps, droppedFrames}` |
| 0x50 | setQuality            | C → S 🔒  | `{preset, cursor?, codec?}` (preset: 0 low, 1 balanced, 2 high, 3 sharp; codec: 1 h264, 2 hevc) |
| 0x52 | hostState             | S → C 🔒  | `{isLocked, isDisplaySleeping, blocksLocalInput?, isLidClosed?, hasExternalDisplay?, hidesDock?, windowActions?, capsLock?}` — `hidesDock`: the Mac hides its Dock for the connected clients (absent before 1.2.13 or when it can't). `blocksLocalInput`: the Mac drops its own keyboard and trackpad input while clients are connected (absent before 1.2.4). `isLidClosed`/`hasExternalDisplay`: the MacBook's lid is shut and whether a display other than the built-in one is active; when both say lid-shut without an external display macOS forces clamshell sleep and the screen can't be streamed. `capsLock`: the Mac's Caps Lock is on (absent before 1.2.27); a change is sent at once, not debounced. Otherwise sent debounced so transient sleep/wake states don't flash the client UI. Fields absent from older Macs |
| 0x53 | wakeDisplay           | C → S 🔒  | empty |
| 0x54 | displays              | S → C 🔒  | `{displays: [{id, name, width, height, isMain}], selectedId?, sizedMirrorAvailable?, mirrorSize?: {width, height}}` — after authentication and whenever the displays, the streamed one or the desktop size change (sizes in points). `sizedMirrorAvailable` and `mirrorSize` are from 1.2.12 |
| 0x55 | selectDisplay         | C → S 🔒  | `{id}` — stream that display; applies to every client. Ignored unless `id` is in the last `displays` |
| 0x56 | setLocalInputBlock    | C → S 🔒  | `{enabled}` — the Mac's setting for blocking its own keyboard and trackpad during sessions; answered with `hostState` |
| 0x57 | setSizedMirror        | C → S 🔒  | `{size?: {width, height}}` — lay the desktop out at that size in points (a virtual display the Mac's main display mirrors, which is then streamed; each side is clamped to 540–2732, and before 1.2.17 the width to 640–2732 and the height to 480–2048), or back at the Mac's own size without `size`; applies to every client and ends with the last session. Answered with `displays` |
| 0x58 | setHideDock           | C → S 🔒  | `{enabled}` — hide the Mac's Dock (its own auto-hide) until the last client leaves, or show it again; applies to every client. Answered with `hostState` |
| 0x59 | textFocus             | S → C 🔒  | `{editable}` — sent shortly after a left click from a client that asked for it: whether the Mac's keyboard focus is in something to type into (from the Accessibility API) |
| 0x5A | setTextFocusReports   | C → S 🔒  | `{enabled}` — turns the `textFocus` reports on or off for this client; off until asked |
| 0x5B | setClipboardSharing   | C → S 🔒  | `{enabled}` — turns clipboard sharing on or off for this client; off until asked. Only clients with it on are sent `clipboard` and have theirs put on the Mac (from 1.2.21) |
| 0x5C | clipboard             | both 🔒   | `{text}` — plain text copied during the session (never what was already on the clipboard when sharing started), for the other side's clipboard. Sent only while the client has `setClipboardSharing` on; bodies over 1 MB are not sent. The Mac passes a client's text on to the other sharing clients (from 1.2.21) |
| 0x5D | clipboardImage        | both 🔒   | binary piece of an image copied during the session (PNG; JPEG for a photo copied as JPEG or an image over 20 MB as PNG), under the same rules as `clipboard`: `[id u32][index u16][count u16][image bytes]` big-endian, pieces of 512 KiB sent back to back and in order with the same `id`; the receiver drops an image whose pieces don't follow on. Images over 20 MB are not sent. When the clipboard has both text and an image, the type the copying app put first is sent (from 1.2.21) |
| 0x60 | bye                   | both 🔒   | `{reason?}` — `host_stopped` means the client must not reconnect on its own |
| 0x70 | requestApps           | C → S 🔒  | empty |
| 0x71 | runningApps           | S → C 🔒  | `{apps: [{bundleId, name, isActive, isHidden, iconPNG?}]}` (icon = base64 PNG) |
| 0x72 | activateApp           | C → S 🔒  | `{bundleId}` |
| 0x73 | systemAction          | C → S 🔒  | `{action}` — `showDesktop`, `missionControl`, `launchpad`, `lockScreen`; from 1.2.16 (when `hostState.windowActions` is true) also `windowClose`, `windowMinimize`, `windowFullScreen`, `windowLeftHalf`, `windowRightHalf`, `windowFill`, which act on the front app's focused window |
| 0x74 | requestFrontWindow    | C → S 🔒  | empty (from 1.2.16) |
| 0x75 | frontWindow           | S → C 🔒  | `{app, title?, isFullScreen}` — the front app's focused window (`title` is absent when it has none); sent in answer to `requestFrontWindow` and after a `window…` system action |
| 0x80 | getHardwareControls   | C → S 🔒  | empty |
| 0x81 | setHardwareControls   | C → S 🔒  | `{brightness?, volume?, isMuted?, sleepDisplay?, lockScreen?}` |
| 0x82 | hardwareControlsState | S → C 🔒  | `{brightness, volume, isMuted}` |

🔒 = encrypted. Data fields (`pubKey`, `signature`, …) are base64 in JSON.

## Handshake and trust

```
Client                                                   Host
  │ hello {deviceId, X25519 ephemeral pubKey} ──────────▶│
  │◀──── serverHello {serverId, X25519 ephemeral pubKey,  │
  │                   Ed25519 identityKey, signature}     │
  │
  │  transcript = SHA-256("rd-handshake-v2", clientKey, deviceId,
  │                       serverKey, identityKey, serverId)   (each field u32-length-prefixed)
  │  signature  = Ed25519(identity, "rd-server-auth-v2" || transcript)
  │  serverId   = hex(SHA-256(identityKey)[0..<16])
  │  keys       = HKDF-SHA256(X25519 secret, salt: transcript,
  │                           info: "rd-v2 client->server" / "rd-v2 server->client")
  │
  │ Paired device:                                        │
  │ authDevice {Ed25519(deviceKey, "rd-device-auth-v2" || transcript)} 🔒 ─▶│
  │   └─ unknown/revoked device ─ authFailed{untrusted}, client asks for the PIN
  │ First pairing:                                        │
  │ authPin {pin, trust, deviceKey} 🔒 ──────────────────▶│  PBKDF2-SHA256(pin, salt, 300k) == stored hash
  │◀─ authOK {trusted, macAddress} 🔒 ───────────────────│  device public key stored if trust requested
  │        (client pins identityKey under serverId)
  │
  │◀══ frame 🔒 ══════════════════════════════════════════│  host also injects input events
  │══ input events 🔒 ▶▶▶▶▶▶▶▶▶▶▶▶▶▶▶▶▶▶▶▶▶▶▶▶▶▶▶▶▶▶▶▶▶▶▶▶│
```

- The client checks that `serverId` is derived from `identityKey` and that the signature
  covers this handshake, before sending anything secret.
- A paired client compares `identityKey` with the key it pinned for that `serverId` (and for the
  Mac it meant to reach). On a mismatch it stops and never sends the PIN or a device proof.
- Device proofs and server signatures are bound to the transcript, so a proof captured by a
  fake host can't be replayed against the real one. No reusable secret crosses the wire.
- First pairing is trust-on-first-use: both devices show the identity fingerprint
  (first 8 bytes of SHA-256(identityKey), e.g. `A1B2 C3D4 E5F6 7890`) so the user can compare.
- PIN attempts are limited across all connections and survive restarts: 5 free failures,
  then a lockout of 30 s doubling per failure up to 1 h (`authFailed{lockedOut, retryAfter}`).
  Only one PIN is verified at a time (`busy`), and at most 5 attempts are allowed per connection.
- The host stores the PIN only as a PBKDF2 hash and paired devices only as public keys.
  Trust can be revoked per device from the Mac's menu bar; the client then falls back to PIN entry.
- Timeouts on the host: `hello` within 10 s, authentication within 120 s (PIN typing), then
  at most 9 s of silence (the client pings every 2 s). At most 16 unauthenticated connections, 2 per address.

## Encryption

Each direction has its own key and a 64-bit message counter starting at 0. A message is
sealed with ChaCha20-Poly1305 using nonce `0x00000000 || counter (BE)` and the 5-byte
frame header as associated data; the counter is never transmitted. The receiver tracks the
same counter, so any replayed, reordered, dropped, re-typed or reflected message fails to
open and the connection is closed.

## Discovery

Bonjour service `_rd-desktop._tcp`. The advertised instance name is
`<ComputerName> [<first 4 hex chars of serverId>]`, and the TXT record carries
`sid` (the server id) and `name`. Clients use `sid` to recognise Macs they've paired with;
because the server id is derived from the identity key, a spoofed `sid` fails the handshake.
