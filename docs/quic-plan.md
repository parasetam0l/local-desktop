# Plan: video over QUIC datagrams

Status: phases 1-2 done. Builds on 1.2.29's frame acks (`frameAck`).

Found while testing phase 2: Network.framework reports the UDP payload size (1,472 on
Wi-Fi) as the flow's `maximumDatagramSize`; datagrams that size never arrived, so pieces
are capped at 1,200 bytes. On iPadOS 17 the client's datagram flow fails with ENETDOWN,
so that iPad keeps video on the QUIC stream (the Mac logs the client's `transportNote`).

## Why

Everything travels on one TCP connection. When Wi-Fi loses a packet, TCP holds
every byte behind it until the resend arrives: the picture, the cursor echo and
the pong all wait. On a good link that stall is usually one Wi-Fi retry, but under
interference it reaches 100-200 ms (the spikes in the host's `delivery` log lines).
A streamer doesn't need a late frame: the next one replaces it. Unreliable
datagrams let a lost frame be skipped while input and control stay reliable.

## Shape

- **One QUIC connection** (Network.framework `NWProtocolQUIC`, iOS 15 / macOS 12,
  already below our minimums), ALPN `localdesktop/1`.
  - **Control stream** (reliable, ordered): every message we have today except
    `frame`, framed and encrypted exactly as now. Input no longer queues behind video.
  - **Video datagrams** (unreliable): each encoded frame split into pieces of about
    1,150 bytes with a header `[frame u32][piece u16][count u16][flags u8]`,
    each sealed with the session's video key (nonce from frame and piece).
- **Security stays ours.** QUIC needs TLS 1.3, so the host presents a self-signed
  certificate and the client accepts it; trust still comes from our handshake
  (host identity key, PIN pairing, device signature) on the control stream, and
  video keys come from that handshake. Nothing changes for pairing.
- **Fallback.** The host advertises `quic=1` in its Bonjour TXT record and listens
  on UDP beside TCP. A new client tries QUIC first and falls back to TCP after
  about a second; old clients and old hosts keep using TCP.

## Losing frames

1. The client reassembles pieces; a frame missing pieces 50 ms after its newer
   neighbour arrived is dropped, and `frameAck` reports the gap.
2. A dropped frame breaks the chain of P-frames. First version: ask for a keyframe
   (what we do today on decoder errors).
3. Better: **long-term references** (`kVTCompressionPropertyKey_EnableLTR`, works
   with the low-latency rate control we now use). The host encodes the next frame
   from the last frame the client confirmed, which is small, instead of a full
   keyframe, which is a burst that causes the next stall.
4. Optional later: one parity piece per group of pieces (XOR FEC), so a single lost
   piece is rebuilt without waiting.

## Phases

| Phase | Work | Check |
|---|---|---|
| 1 | QUIC connection, control stream, video still on a reliable stream; TXT flag and TCP fallback | Loopback test over QUIC; same behavior as TCP |
| 2 | Video as datagrams, splitting and reassembly, drop and keyframe on loss | Unit tests for reassembly; `delivery` log max drops on the iPad |
| 3 | LTR recovery instead of keyframes | Loss test (Network Link Conditioner, 2 % loss): no keyframe bursts |
| 4 | FEC, if phase 3 still shows visible freezes | Same loss test |

Each phase ships on its own and keeps TCP as the fallback.

## Risks

- QUIC's own congestion control also covers datagrams; it could fight our bitrate
  control. Phase 1 measures this before anything depends on it.
- Network.framework QUIC datagram size must fit the path MTU; pieces are kept under
  1,200 bytes to be safe.
- Wi-Fi stalls from the radio itself (AirDrop/Handoff scanning, power saving)
  still delay packets; QUIC only stops one late packet from holding back the rest.

## Effort

Phases 1-2 are the bulk: a new transport on both sides, with protocol and crypto
changes, so a `high` effort piece. Phase 3 is `medium`, phase 4 `medium`.
