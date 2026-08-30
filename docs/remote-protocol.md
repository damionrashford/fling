# Remote Protocol

`Sources/FlingKit/AndroidTVRemote/` is a from-scratch Swift implementation of
the Android TV Remote protocol v2 — the protocol the Google TV mobile app and
physical remotes speak. No dependencies: hand-rolled protobuf, Network.framework
TLS, Security.framework certificates. Semantics were ported from the
field-tested reference implementation
([tronikos/androidtvremote2](https://github.com/tronikos/androidtvremote2))
and verified byte-for-byte with golden tests.

## Two channels

| Port | Purpose | Lifetime |
|---|---|---|
| 6467 | Pairing (the "polo" protocol) | One-shot, per Mac × TV |
| 6466 | Remote session (keys, apps, IME, voice, state) | Long-lived, reconnects on demand |

Both are TLS with a **self-signed client certificate** as the identity. The
certificate is generated once (RSA-2048 via `openssl`, stored in
`~/Library/Application Support/Fling/`, imported into the keychain as
"Fling Android TV Remote") and is what the TV remembers at pairing time.

## Pairing (port 6467)

```
client                                  TV
  ── PairingRequest ──────────────────▶
  ◀─ ack ──────────────────────────────
  ── PairingOption (hex, 6, input) ───▶
  ◀─ PairingOption ────────────────────
  ── PairingConfiguration ────────────▶
  ◀─ ConfigurationAck ─────────────────      TV displays 6-char PIN
  ── PairingSecret ───────────────────▶      SHA-256 over both certs' RSA
  ◀─ SecretAck ────────────────────────      numbers + PIN nonce
```

The secret hashes the client and server RSA public-key numbers
(big-endian magnitudes, DER sign-padding stripped) plus the last four PIN
characters; the first two PIN characters are a checksum validated client-side
before anything is sent — a mistyped PIN fails locally, instantly.

## Session (port 6466)

The server speaks first:

```
  ◀─ RemoteConfigure (code1 = TV's feature bits)
  ── RemoteConfigure reply (our features ∩ TV's, device info) ─▶
  ◀─ RemoteSetActive
  ── RemoteSetActive (active = negotiated bits) ─▶
  ◀─ RemoteStart (started)          ← power state, pushed again on change
```

After the handshake: `RemoteKeyInject` (any Android keycode, `ATVKeyCode`),
`RemoteAppLinkLaunchRequest` (app links — see hardware notes below),
`RemoteImeBatchEdit` (whole-string text commit into the focused field),
`RemoteVoice{Begin,Payload,End}` (mic streaming), plus ping/pong keepalives
answered automatically. `RemoteImeKeyInject` carries the foreground app's
package, surfaced as the `.appChanged` event.

### Feature negotiation and the voice fallback

We request `PING|KEY|IME|POWER|VOLUME|APP_LINK` and, when voice is enabled,
`VOICE`. The reference library defaults voice off, so voice-negotiating
clients are rare in the wild; if a TV kills the session *after TLS but before
RemoteStart*, the client retries once without the voice bit and remembers.
Pre-TLS failures (TV off, network blip) never trigger or latch the fallback.
Live verification: TCL Google TV accepts the voice bit (`active=0x26f`).

### Voice

16-bit PCM, mono, 8 kHz. Chunks are padded to ≥8 KB and split at 20 KB — 
outside those bounds the TV drops the connection. `beginVoice` performs the
KEYCODE_SEARCH → `RemoteVoiceBegin` handshake (2 s deadline) with the
continuation registered *before* the key is sent, matching the reference's
ordering. Mac-side capture (`VoiceCapture`) converts any input format to the
wire format and emits exact-size chunks so mid-utterance padding never
injects silence.

## Lifecycle guarantees

- **One connect at a time**: concurrent callers join a single in-flight
  connect task; a superseded connect can never tear down its replacement.
- **Host switches reconnect**: commands aimed at a different TV than the
  connected one tear down and re-handshake — two-TV households can't
  cross-fire.
- **Exactly one `.disconnected`** reaches subscribers per lost session.
- **Deadlines are real**: every await is bounded (`withATVDeadline` cancels
  the transport on expiry and reports `connectionTimeout` deterministically).

## Diagnostics

Every session writes to `~/Library/Logs/Fling.log`:

```
2026-08-30T00:24:35.412Z [remote] connect 192.168.1.73:6466 requesting features=0x26f
2026-08-30T00:24:35.598Z [conn] 192.168.1.73:6466 tls established
2026-08-30T00:24:35.601Z [remote] recv RemoteConfigure code1=0x27f; send reply active=0x26f
2026-08-30T00:24:35.610Z [remote] handshake complete active=0x26f isOn=true
```

## Hardware notes (verified on TCL Google TV)

- **App links**: custom schemes (`netflix://`, `vnd.youtube.launch://`,
  `spotify://`) launch directly; `https` links work only when the app has
  verified its domain (Tubi); `market://launch?id=…` opens nothing useful on
  TCL. The catalog in `TVApp.swift` records the verified forms.
- **Power state is a lie on standby-networked sets**: TCL's Quick
  Start/Network Standby keeps the remote service running, so `RemoteStart`
  reports started even with the panel dark. The power key works; the state
  flag reflects service availability, not electrons
  ([HA integration notes](https://www.home-assistant.io/integrations/androidtv_remote/)).
- **IME text** lands only when a text field is focused on-screen; the TV
  silently drops edits otherwise.
