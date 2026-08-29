<div align="center">

# Fling

**Your TV, from the Mac menu bar.**

Cast any browser tab to a Chromecast / Google TV — and drive the TV itself:
power, apps, d-pad, volume, typing, voice search.

![Swift 6](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)
![Universal](https://img.shields.io/badge/binary-universal-4B8BBE)
![Tests](https://img.shields.io/badge/tests-206%20passing-2EA44F)

<img src=".github/panel.png" width="640" alt="Fling's Cast page while playing, and the Remote page with app launcher, d-pad, volume, and voice search">

</div>

---

## Install

Paste in Terminal:

```sh
curl -fsSLO https://raw.githubusercontent.com/damionrashford/fling/main/Scripts/get-fling.sh
bash get-fling.sh
```

That's the whole install — and the update command too. It pulls the universal
binary straight from this repo, assembles the app in /Applications, installs
the Cast engine ([catt](https://github.com/skorokithakis/catt) via
[uv](https://docs.astral.sh/uv/)), and launches it. curl downloads carry no
quarantine flag, so there is no Gatekeeper "Open Anyway" dance.

> **Requirements** — macOS 14+, on the same Wi-Fi network as the TV.

## Features

| Cast | Remote |
|---|---|
| Cast the frontmost Chrome or Safari tab (⌘⇧C) | True power on/off over the Android TV Remote protocol |
| Cast a URL from the clipboard | App launcher with the TV's foreground app highlighted |
| Play/pause, seek, debounced volume slider | D-pad, OK, Back, Home |
| Artwork, progress, playback state | Instant volume and mute — raw keycodes, no subprocess lag |
| Works with YouTube, direct media, extractable sites | Type on the TV from the Mac keyboard |
| | Voice search — the mic button streams the Mac microphone to the TV |
| | CEC wake button that works before pairing |

## First run

1. Approve the browser-access prompts — that's how Fling reads the current tab.
2. **Remote** tab → **Set Up TV Power…** — the TV displays a 6-character
   code; type it in. Once per Mac.
3. Voice search asks for microphone access on first use.

## Build from source

```sh
swift build && swift test    # 206 tests
./Scripts/bundle.sh          # signed .app in build/ (identity in Scripts/signing-identity.local, else ad-hoc)
./Scripts/publish-bin.sh     # refresh bin/Fling, the binary the installer serves
```

`Fling --preview-panel` renders every panel state in one window for design
work; `FLING_PREVIEW=hero` renders the two-panel shot above.

## Architecture

- **Casting** shells out to [`catt`](https://github.com/skorokithakis/catt)
  (pychromecast underneath).
- **Remote** is a from-scratch, dependency-free Swift implementation of the
  Android TV Remote protocol v2 in
  [`Sources/FlingKit/AndroidTVRemote/`](Sources/FlingKit/AndroidTVRemote/):
  TLS client-certificate pairing on port 6467, a protobuf message channel on
  6466 — key events, app links, IME text, and PCM voice streaming, with
  hand-rolled protobuf and golden-byte tests throughout.
- **Wake without pairing** launches a throwaway cast receiver; the TV's
  HDMI-CEC "One Touch Play" turns the panel on.

Everything runs on your LAN. Nothing phones home.
