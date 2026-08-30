# Architecture

Fling is three layers in one Swift package, dependency-free beyond the
system SDKs and the external `catt` CLI.

```
┌────────────────────────────────────────────────────────┐
│  Fling (executable target) — presentation              │
│  StatusItemController · PanelView · RemoteView         │
│  GlobalShortcuts · ScrollRemote · ContextMenuBuilder   │
└──────────────────────────┬─────────────────────────────┘
                           │ observes / calls (@MainActor)
┌──────────────────────────▼─────────────────────────────┐
│  FlingKit (library target) — state & integrations      │
│  AppState (the hub) · CastPlanner · TabProber          │
│  CattClient/CattParser · BrowserSource · VoiceCapture  │
└──────┬──────────────────┬──────────────────┬───────────┘
       │ subprocess       │ osascript        │ TLS/protobuf
┌──────▼──────┐   ┌───────▼───────┐   ┌──────▼───────────┐
│ catt        │   │ Chrome/Safari │   │ AndroidTVRemote/ │
│ (casting)   │   │ (tab + probe) │   │ (TV control)     │
└─────────────┘   └───────────────┘   └──────────────────┘
```

## The state hub

`AppState` is the single `@MainActor ObservableObject`. Every published
property the UI renders and every user action lives here. Its rules:

- **All I/O off the main actor.** Subprocess calls (`catt`, `osascript`) and
  network sessions run in detached tasks or actors; results hop back to the
  main actor for publishing.
- **Interaction generations.** Explicit user choices (switching TV or
  browser) bump `interactionGeneration`; an in-flight refresh that started
  before the bump discards its results instead of painting stale state over
  the user's choice.
- **Two refresh weights.** `refresh()` reads browser tab + probe + cast
  status, publishing as soon as the fast pass lands, with the ~10 s first-run
  device scan arriving separately. `refreshStatus()` is the closed-panel
  poll: one `catt status`, nothing else.
- **Errors are values.** Every failure ends in `lastError`, rendered by one
  panel line. Remote-protocol failures additionally log to
  `~/Library/Logs/Fling.log`.

## Process boundary

`ProcessRunning` is the seam for every subprocess. It returns a structured
`ProcessResult` (exit code, stdout, stderr, timed-out flag) so callers branch
on real signals rather than sniffing substrings — a media title containing
"timed out" must never read as an error. `SystemProcessRunner` enforces
per-command timeouts (SIGTERM → SIGKILL) so a wedged helper can never freeze
the app. Tests substitute `FakeRunner`; the preview harness substitutes a
stub that never spawns anything.

## Browser boundary

Tab reading and the media probe go through Apple Events (`osascript -l
JavaScript`), the sanctioned macOS channel into Chrome's and Safari's tab
models — gated by the per-app Automation consent the onboarding flow
requests. Liveness and frontmost checks use `NSWorkspace` in-process: zero
subprocess spawns. Browser identity has one source of truth, the `Browser`
enum.

## TV boundary

`AndroidTVRemote/` is a self-contained actor-based subsystem; the app layer
sees a small facade (`connect`, `pressKey`, `launchApp`, `sendText`,
`togglePower`, voice methods, and an `AsyncStream` of session events). See
[Remote Protocol](remote-protocol.md).

## UI composition

One panel, one screen (no tabs): the cast section flows into the "On the TV"
section, with housekeeping and the device footer as fixed chrome — the
footer is the last row in every state. `MenuRow`/`KeyButton`/`KeyPill` are
the row/key primitives. The scroll-to-navigate gesture is an
`NSEvent` local monitor (`ScrollRemote`) feeding a pure, unit-tested
accumulator (`ScrollNav`) that discretizes trackpad deltas into d-pad steps.

## Threading model at a glance

| Component | Isolation |
|---|---|
| AppState, all UI | `@MainActor` |
| ATVRemoteClient, ATVPairingClient, AndroidTVRemote | actors |
| Subprocess + osascript work | detached tasks |
| VoiceCapture tap | audio render thread (lock-guarded buffer) |
