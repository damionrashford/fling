# Casting Pipeline

Casting delegates to [`catt`](https://github.com/skorokithakis/catt)
(pychromecast + yt-dlp underneath), driven over a structured subprocess seam.
The interesting engineering is in deciding *what* to cast.

## From tab to plan

```
browser tab ──▶ URLClassifier ──▶ CastKind
                                     │
page player ──▶ TabProber ──▶ TabMedia
                                     │
                    CastPlanner.plan(tab, media) ──▶ CastPlan
                                     │        (url, kind, seekTo)
                          CattClient.cast(--seek-to)
```

**URLClassifier** buckets a URL: YouTube (cast the page URL — the YouTube
receiver handles it), direct media (`catt cast -f`), extractable sites
(yt-dlp cracks them from the URL alone), or not castable.

**TabProber** injects a read-only script into the active tab via Apple
Events (`execute javascript` / `do JavaScript`) and reads the page's actual
players: every `<video>`/`<audio>` element's source, position, duration and
paused state, plus HLS/DASH manifest URLs sniffed from the page's resource
log — the escape hatch for MSE players whose `currentSrc` is an uncastable
`blob:` URL. Requires the browser's one-time **Allow JavaScript from Apple
Events** toggle (per-profile in Chrome); when it's off the panel shows a
hint and casting silently degrades to URL-only. A probe failure can never
block a cast.

**CastPlanner** merges the two signals:

| Situation | Plan |
|---|---|
| YouTube page | page URL, `.youtube`, seek attached |
| Probe found an http(s) stream or manifest | stream URL, `.directMedia`, seek attached |
| Media present but blob-only, no manifest | fall back to the tab's own kind |
| No media | tab URL and kind as classified |

Resume positions under 5 s (`CastPlanner.resumeThreshold`) are discarded at
both the prober and the planner — the constant is shared so the gates cannot
drift.

## The cast row

The panel's primary row *is* the plan: it reads "Resume on TV at 12:34" when
a resume exists, and a page the classifier rejected but the probe made
castable gets an enabled row (the panel state consults the planner, not the
raw classification). A cast in flight disables the row ("Casting…") — yt-dlp
extraction can take 10+ seconds and a second click would kill the loading
session.

## catt specifics worth knowing

- Targeting is **by IP**, never name: name targeting re-runs mDNS discovery
  per command and intermittently misses.
- `catt` exits 0 while printing `Error:` lines to stdout; error detection is
  line-aware and structured (exit code + stderr + `Error:` prefixes), so a
  media title containing "timed out" cannot fake a failure.
- Every command has a timeout (scan 60 s, cast 120 s for yt-dlp, default
  30 s); a hung helper is SIGTERM/SIGKILLed and reported distinctly.
- **Wake** has no cast-protocol power command: launching any receiver app
  fires HDMI-CEC "One Touch Play". The launch ack is ignored (it routinely
  outlives pychromecast's wait) and the follow-up `stop` is retried with
  backoff until the TV answers — confirmation, not a guessed sleep.

## Volume, twice

The cast-page slider sets the *stream* volume through catt (debounced 180 ms
— slider drags emit an event per pixel and each would spawn a subprocess).
The TV-section Vol−/Mute/Vol+ pills send raw keycodes over the remote
session: instant, and they work outside cast sessions. Paired-and-idle shows
only the pills; two volume controls at once read as a mistake.
