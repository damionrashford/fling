# Fling

A macOS menu bar app that owns the living room TV: cast the current browser
tab (Chrome or Safari) to a Chromecast / Google TV, and drive the TV itself —
power, app launcher, d-pad, instant volume, typing into TV fields, and voice
search from the Mac microphone — over the Android TV Remote protocol.

## Install (no App Store)

1. Download `Fling-Install.zip` from [Releases](../../releases), unzip.
2. Right-click **Install Fling.command** → Open → Open. One time only —
   the app ships outside the App Store, so plain double-click is blocked.
3. The installer copies Fling to /Applications, installs the Cast engine
   ([catt](https://github.com/skorokithakis/catt) via [uv](https://docs.astral.sh/uv/)),
   and launches the app.

Requirements: macOS 14+, same Wi-Fi network as the TV.

First run: approve the browser-access prompts, then open the **Remote** tab
and click **Set Up TV Power…** — the TV displays a 6-character code; type it
in. Pairing is once per Mac.

## Build from source

```sh
swift build && swift test
./Scripts/bundle.sh      # signed .app in build/ (put your identity in Scripts/signing-identity.local)
./Scripts/package.sh     # shareable installer zip
```

`Fling --preview-panel` renders every panel state in a window for design work.

## How it talks to the TV

- **Casting**: shells out to `catt` (pychromecast underneath).
- **Remote**: a from-scratch Swift implementation of the Android TV Remote
  protocol v2 — TLS client-cert pairing on port 6467, protobuf remote channel
  on 6466 — in `Sources/FlingKit/AndroidTVRemote/`. No dependencies.
- **Wake without pairing**: launching any cast receiver fires HDMI-CEC
  "One Touch Play", which powers the panel on.
