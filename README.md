# Fling

A macOS menu bar app that owns the living room TV: cast the current browser
tab (Chrome or Safari) to a Chromecast / Google TV, and drive the TV itself —
power, app launcher, d-pad, instant volume, typing into TV fields, and voice
search from the Mac microphone — over the Android TV Remote protocol.

## Install

Paste in Terminal:

```sh
curl -fsSLO https://raw.githubusercontent.com/damionrashford/fling/main/Scripts/get-fling.sh
bash get-fling.sh
```

It pulls the universal binary straight from this repo, assembles the app in
/Applications, installs the Cast engine
([catt](https://github.com/skorokithakis/catt) via
[uv](https://docs.astral.sh/uv/)), and launches it. curl downloads skip
Gatekeeper quarantine, so no "Open Anyway" dance.

Requirements: macOS 14+, same Wi-Fi network as the TV.

First run: approve the browser-access prompts, then open the **Remote** tab
and click **Set Up TV Power…** — the TV displays a 6-character code; type it
in. Pairing is once per Mac.

## Build from source

```sh
swift build && swift test
./Scripts/bundle.sh      # signed .app in build/ (put your identity in Scripts/signing-identity.local)
./Scripts/publish-bin.sh # refresh bin/Fling, the binary the installer serves
```

`Fling --preview-panel` renders every panel state in a window for design work.

## How it talks to the TV

- **Casting**: shells out to `catt` (pychromecast underneath).
- **Remote**: a from-scratch Swift implementation of the Android TV Remote
  protocol v2 — TLS client-cert pairing on port 6467, protobuf remote channel
  on 6466 — in `Sources/FlingKit/AndroidTVRemote/`. No dependencies.
- **Wake without pairing**: launching any cast receiver fires HDMI-CEC
  "One Touch Play", which powers the panel on.
