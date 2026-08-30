# Development

## Build and test

```sh
swift build                  # debug build
swift test                   # full suite — no TV, no browsers, no network
./Scripts/bundle.sh          # signed .app in build/
./Scripts/publish-bin.sh     # refresh bin/Fling (what the installers serve)
```

Signing identity comes from the untracked `Scripts/signing-identity.local`;
without it, `bundle.sh` falls back to ad-hoc signing (works, but macOS
Automation grants reset whenever the signature changes — use a stable
identity on your own machine).

**Concurrent work convention**: parallel workstreams build with private
scratch paths (`swift build --scratch-path .build-<name>`) so they never
contend for the default `.build` lock. All `.build*/` paths are gitignored.

## The test suite

299 tests, ~3 s, fully hermetic: subprocesses are faked through the
`ProcessRunning` seam, the TV transport through `ATVTransporting`, and the
protocol layer is pinned by golden-byte tests hand-derived from the proto
field numbers. When behavior was verified against real hardware, the test
carries the expectation (e.g. catt argv shapes, TCL launch-ack tolerance).

## Preview harness

The menu bar popover can't be opened programmatically, so the panel is
rendered in a plain window for design work:

```sh
.build/debug/Fling --preview-panel        # all panel states, stub I/O
FLING_PREVIEW=hero .build/debug/Fling --preview-panel   # the README shot
```

No subprocess ever spawns and no device is contacted — safe to run anywhere.
Screenshot it to review design changes; the README hero image comes from the
`hero` mode.

## Live hardware driver

`LiveATVTests` is a gated driver for iterating against a real, paired TV —
it does nothing unless the env var is set:

```sh
FLING_LIVE_ATV_HOST=<tv-ip> FLING_LIVE_ATV_ACTION=read   swift test --filter LiveATV
# actions: read | key:<code> | app:<link> | text:<string> | power
```

`read` is invisible on-screen (connect, report power state, disconnect);
everything else visibly drives the TV — aim it at a set nobody is watching.
Cross-check results over the cast channel (`catt -d <ip> info` shows the
foreground app) and read `~/Library/Logs/Fling.log` for the wire exchange.

## Adding an app to the launcher

One entry in `TVApp.catalog` (`Sources/FlingKit/TVApp.swift`): display name,
launch link, Android package (used to highlight the foreground app). Prefer
a custom scheme; use `https` only if the app verifies its domain on-device;
avoid `market://` — it does not launch apps on TCL. Verify with the live
driver: `FLING_LIVE_ATV_ACTION=app:<link>`.

## Conventions

- Comments state constraints the code can't show — no narration, no
  changelogs in code.
- One error surface: user-visible failures end in `AppState.lastError`;
  remote-protocol detail goes to `~/Library/Logs/Fling.log`.
- Shared magic numbers get one home (`AppState.seekStep`,
  `CastPlanner.resumeThreshold`, `ATVRemoteMessage.voiceChunkMinSize`).
- Ship gates run on exit codes, never on grepping output.
