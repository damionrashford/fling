# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-08-29

### Added

- Menu bar panel that casts the current Chrome or Safari tab to a
  Chromecast / Google TV, with playback controls, artwork, progress, and a
  debounced stream-volume slider.
- System-wide ⌘⇧C shortcut that casts the frontmost browser tab.
- Clipboard URL casting.
- Resume-from-position casting: an in-page probe reads the tab's actual
  player and the cast starts where the video left off; blob-based players
  are cast via their sniffed HLS/DASH manifest.
- Full TV remote over a dependency-free Android TV Remote protocol v2
  implementation: one-time PIN pairing, power, d-pad with Back/Home,
  instant volume and mute, and typed text into the TV's focused field.
- App launcher with hardware-verified deep links (YouTube, Netflix,
  Prime Video, Disney+, Spotify, Plex, Tubi) and foreground-app highlighting.
- Voice search: the Mac microphone streams to the TV's voice input.
- Scroll-to-navigate: trackpad and mouse-wheel gestures over the open panel
  drive the TV's d-pad, with momentum ignored and steps rate-limited.
- CEC "One Touch Play" wake that powers the TV on without pairing.
- Multi-TV support with per-device pairing and a device switcher.
- One-command installers — a curl script and `npx github:damionrashford/fling`
  — that assemble the app from the repo-served universal binary with no
  Gatekeeper prompts.
- Session diagnostics log at `~/Library/Logs/Fling.log`.

[unreleased]: https://github.com/damionrashford/fling/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/damionrashford/fling/releases/tag/v1.0.0
