# Local Desktop wire protocol (v1)

TCP transport (Network.framework). Every message is framed as:

```
+--------------------+---------+---------------------------+
| u32 length (BE)    | u8 type | payload (`length` bytes)  |
+--------------------+---------+---------------------------+
```

Video frames use a binary payload: `[u16 width BE][u16 height BE][u8 codec][pixels]`.
Codec `0` = JPEG, `1` = H.264. All other messages carry a JSON body. Max payload: 32 MiB.

## Message types

| Type | Name           | Direction  | Body (JSON) |
|------|----------------|------------|-------------|
| 0x01 | hello          | C → S      | `{version, deviceId, deviceName, pubKey}` |
| 0x02 | serverHello    | S → C      | `{version, serverId, serverName, pubKey, requiresPin}` |
| 0x03 | authPin        | C → S 🔒   | `{pin, trust}` |
| 0x04 | authToken      | C → S 🔒   | `{token}` |
| 0x05 | authOK         | S → C 🔒   | `{serverName, trusted, token?}` |
| 0x06 | authFailed     | S → C      | `{reason}` |
| 0x10 | frame          | S → C 🔒   | binary (see above) |
| 0x20 | mouseMoveAbs   | C → S 🔒   | `{x, y}` — frame pixel space |
| 0x21 | mouseMoveRel   | C → S 🔒   | `{dx, dy}` — screen points |
| 0x22 | mouseDown      | C → S 🔒   | `{button}` (0 left, 1 right) |
| 0x23 | mouseUp        | C → S 🔒   | `{button}` |
| 0x24 | scroll         | C → S 🔒   | `{dx, dy}` — lines; dy > 0 scrolls toward document end |
| 0x30 | keyEvent       | C → S 🔒   | `{code, down, flags}` — Mac virtual key code, flags = modifier bitmask (shift 1, ctrl 2, alt 4, cmd 8) |
| 0x31 | textEvent      | C → S 🔒   | `{s}` — unicode text |
| 0x40 | ping           | C → S 🔒   | `{t}` |
| 0x41 | pong           | S → C 🔒   | `{t}` |
| 0x50 | setQuality     | C → S 🔒   | `{preset, cursor?}` (preset: 0 low, 1 balanced, 2 high, 3 sharp. cursor: true to show mac cursor) |
| 0x60 | bye            | both       | `{reason?}` |

🔒 = payload encrypted with the session key (`nonce(12) || ciphertext || tag(16)`, ChaCha20-Poly1305).

## Handshake and trust flow

```
Client                                Host
  │ hello (ephemeral X25519 pub) ────▶│
  │◀──────────── serverHello (X25519 pub, serverId, serverName)
  │        both derive sessionKey = HKDF(X25519(secret), salt "rd-session-v1")
  │
  │ authToken {token} 🔒 ────────────▶│  token from Keychain (if trusted before)
  │   └─ invalid? ─ authFailed, client falls back to PIN
  │ authPin {pin, trust} 🔒 ─────────▶│  PBKDF2-SHA256(pin, salt, 60k) == stored hash
  │◀─ authOK {trusted, token?} 🔒 ────│  new 256-bit token issued if trust requested
  │        (client stores token in Keychain under serverId)
  │
  │◀══ frame 🔒 (JPEG) ═══════════════│  host also injects input events
  │══ input events 🔒 ▶▶▶▶▶▶▶▶▶▶▶▶▶▶▶│
```

- PIN verification is capped at 5 failures per connection.
- The host stores only PBKDF2 hashes of the PIN and SHA-256 hashes of trust tokens.
- Trust can be revoked per device from the Mac's menu bar UI; the client then
  falls back to PIN entry on its next connection.

## Discovery

Bonjour service `_rd-desktop._tcp`. The advertised instance name is
`<ComputerName> [<first 4 hex chars of serverId>]`, which keeps multiple Macs
distinguishable while remaining human-readable.
