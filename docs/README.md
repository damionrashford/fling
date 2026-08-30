# Fling Documentation

Deep documentation for contributors and the curious. User-facing basics —
install, quick start, troubleshooting — live in the [root README](../README.md).

| Document | What it covers |
|---|---|
| [Architecture](architecture.md) | The three layers, data flow, state model, threading rules |
| [Remote Protocol](remote-protocol.md) | The from-scratch Android TV Remote v2 implementation: pairing, session, voice, framing |
| [Casting Pipeline](casting.md) | URL classification, the in-page media probe, cast planning, resume |
| [Development](development.md) | Building, testing, the preview harness, the live hardware driver |
| [Distribution](distribution.md) | The repo-served binary, installers, the signing model and its trade-offs |

## Orientation in five sentences

Fling is a macOS menu bar app with no dock icon and one panel. Casting is
delegated to [`catt`](https://github.com/skorokithakis/catt) via subprocess;
TV control (power, apps, d-pad, typing, voice) is a native Swift
implementation of the Android TV Remote protocol v2 with zero dependencies.
All state funnels through one `@MainActor` observable object, `AppState`;
all I/O runs off the main actor. Everything operates on the local network —
there is no server component anywhere. The test suite (299 tests) runs
without a TV; a gated live driver exists for hardware verification.
