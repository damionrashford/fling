# Distribution

Fling ships outside the App Store with no paid developer account. The design
goal: install and update in one command, with zero Gatekeeper friction.

## How the install works

The repo itself is the distribution channel. `bin/Fling` is a committed
universal binary (Apple Silicon + Intel), **ad-hoc signed so it carries no
personal identity**. Two installers assemble the app from it:

| Installer | Command |
|---|---|
| curl | `curl -fsSLO https://raw.githubusercontent.com/damionrashford/fling/main/Scripts/get-fling.sh && bash get-fling.sh` |
| npx / bunx | `npx github:damionrashford/fling` |

Both download `bin/Fling` + `Resources/Info.plist` over HTTPS, assemble
`/Applications/Fling.app`, sign it ad-hoc locally, install the Cast engine
(`uv` → `catt`) if missing, and launch. Re-running either updates in place.

**Why there is no Gatekeeper prompt**: quarantine is applied to *browser*
downloads. `curl`, `npx`, and `fetch` downloads carry no quarantine
attribute, so the assembled app opens like any local build. This is the
documented macOS behavior, not a bypass of anything.

## The trade-offs, honestly

- **Permission prompts return after updates.** macOS keys Automation and
  Microphone consent to the code signature; every ad-hoc build is a new
  signature. One approval per update is the cost of shipping unsigned.
- **No auto-update.** Re-running the one-liner *is* the update mechanism.
- **The clean fix exists**: an Apple Developer Program membership
  (Developer ID + notarization) would give double-clickable downloads,
  stable permission grants, and Sparkle-style updates. Deliberately not
  purchased yet.

## Releasing a change

```sh
./Scripts/publish-bin.sh     # rebuild the universal binary into bin/
git add bin/Fling && git commit && git push
```

Whatever is on `main` is what the installers serve — there is no separate
release artifact. Keep `bin/Fling` in lockstep with the sources in the same
push.

## What never ships

`Scripts/signing-identity.local` (personal identity), `docs-archive`, build
products, and all local tooling directories are gitignored. The committed
binary is scrubbed by construction: ad-hoc signatures embed no certificate
identity.
