# Fling

Your TV, from the Mac menu bar. Fling casts the current browser tab to a
Chromecast / Google TV and doubles as a full remote for the TV itself — no
phone, no TV remote, no App Store.

## Install

Paste in Terminal:

```sh
curl -fsSLO https://raw.githubusercontent.com/damionrashford/fling/main/Scripts/get-fling.sh
bash get-fling.sh
```

That's the whole install. It pulls the universal binary (Apple Silicon +
Intel) straight from this repo, assembles the app in /Applications, installs
the Cast engine ([catt](https://github.com/skorokithakis/catt) via
[uv](https://docs.astral.sh/uv/)), and launches it. curl downloads carry no
quarantine flag, so there is no Gatekeeper "Open Anyway" dance. Re-run the
same two lines any time to update.

**Requirements:** macOS 14+, same Wi-Fi network as the TV.

## What it does

**Cast page**
- Cast the frontmost Chrome or Safari tab (⌘⇧C) or a URL from the clipboard
- Playback controls, seek, debounced volume slider
- Artwork, progress, and state for whatever is playing

**Remote page**
- Real power on/off over the Android TV Remote protocol
- App launcher — YouTube, Netflix, Prime Video, Disney+, Spotify, Plex, Tubi —
  with the TV's current foreground app highlighted
- D-pad, OK, Back, Home
- Instant volume and mute (no subprocess lag — raw keycodes on a live session)
- Type on the TV from your Mac keyboard
- Voice search: the mic button streams your Mac microphone to the TV
- Works before pairing too: a CEC "One Touch Play" wake button

## First run

1. Approve the browser-access prompts (that's how Fling reads the current tab).
2. Open the **Remote** tab → **Set Up TV Power…** — the TV displays a
   6-character code. Type it in. Once per Mac.
3. Voice search asks for microphone access on first use.

## Build from source

```sh
swift build && swift test    # 206 tests
./Scripts/bundle.sh          # signed .app in build/ (identity in Scripts/signing-identity.local, else ad-hoc)
./Scripts/publish-bin.sh     # refresh bin/Fling, the binary the installer serves
```

`Fling --preview-panel` renders every panel state in one window for design work.

## How it talks to the TV

- **Casting** shells out to `catt` (pychromecast underneath).
- **Remote** is a from-scratch, dependency-free Swift implementation of the
  Android TV Remote protocol v2 in `Sources/FlingKit/AndroidTVRemote/`:
  TLS client-certificate pairing on port 6467, a protobuf message channel on
  6466 — key events, app links, IME text, and PCM voice streaming, with
  hand-rolled protobuf and golden-byte tests throughout.
- **Wake without pairing** launches a throwaway cast receiver; the TV's
  HDMI-CEC "One Touch Play" turns the panel on.
