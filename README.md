# *screc*

[![Build](https://github.com/kleinzeug/screc/actions/workflows/build.yml/badge.svg)](https://github.com/kleinzeug/screc/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform: macOS 15+](https://img.shields.io/badge/platform-macOS%2015%2B-lightgrey.svg)

***screc*** is a one-click menu-bar screen recorder for macOS that produces small,
share-ready MP4s (or GIFs) with zero post-processing.

A [Kleinzeug](https://github.com/kleinzeug) tool — small tools, properly made.
Home: [screc.app](https://screc.app) · Source: [github.com/kleinzeug/screc](https://github.com/kleinzeug/screc)

Click the red dot in the menu bar, do the thing, click stop — the compressed,
share-ready file already exists. No export dialog, no ffmpeg incantation, no
subscription.

| Mode | What it records |
|---|---|
| Focused window | follows focus as you switch windows |
| Selected window | one pinned window, optionally a sub-region inside it — survives the window closing and reopening |
| Screen region | drag it out, then nudge edges and corners (⇧ locks aspect, ⌥ mirrors) |
| Full screen | per display |

Global hotkeys, all rebindable in Settings:

| | |
|---|---|
| ⌘⇧8 | Selected Window |
| ⌘⌥⇧8 | Focused Window |
| ⌘⇧9 | Full Screen |
| ⌘⌥⇧9 | Screen Region |
| ⌘⇧0 | Stop recording |

Each mode hotkey starts from what that mode last recorded, so the second
press of ⌘⌥⇧9 re-records the same region without asking.

Output is live-encoded H.264/HEVC at your target bitrate, or GIF (auto-converted
on stop, with an in-app frame editor for trimming frames). Recordings land in
`/tmp/screc` by default, so they clean themselves up on reboot.

See [DESIGN.md](DESIGN.md) for the architecture, the research behind it, and the
milestone plan. Current state: **M4** — feature-complete and in daily use.
Next: notarized Developer ID build (M5), then a Mac App Store variant (M6).

## Getting ***screc***

**Build it yourself.** That is the primary way to get ***screc***, it is free, and it
stays free — the source here is complete, with no crippled features and no
paywalled build. Instructions below.

**Or buy it** (planned): a Mac App Store release for a small one-time price,
for people who would rather not touch a compiler. Never a subscription. Nobody
who is willing to run `xcodegen generate` ever needs to pay for this.

## Building

Requirements: **macOS 15+**, **Xcode 26+**.

The Xcode project is generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen), so the `.xcodeproj` stays out
of version control conflicts:

```sh
git clone https://github.com/kleinzeug/screc.git
cd screc

brew install xcodegen        # once
xcodegen generate            # writes screc.xcodeproj

open screc.xcodeproj         # build & run from Xcode (⌘R)
```

Prefer the command line:

```sh
xcodebuild -project screc.xcodeproj -scheme screc \
           -configuration Debug -derivedDataPath build build

open build/Build/Products/Debug/screc.app
```

The one dependency, [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)
(MIT), resolves automatically via Swift Package Manager on first build.

### First run: screen-recording permission

macOS gates screen capture behind a privacy permission that **only takes effect
after the app is relaunched** — this is macOS behavior, not a bug in ***screc***. The
welcome window walks you through it: grant access, then hit *Relaunch screc*.

If the menu-bar icon shows a hollow dot, permission is still missing. Enable
***screc*** under **System Settings → Privacy & Security → Screen & System Audio
Recording** and relaunch.

### Signing

A clean clone builds **ad-hoc signed** — no Apple account needed, which is
what CI does too. `Config/signing.xcconfig` holds those defaults and
optionally includes `Config/local.xcconfig`, which is gitignored and where
your own identity goes:

```sh
cp Config/local.xcconfig.example Config/local.xcconfig
# then set DEVELOPMENT_TEAM to your team id and re-run xcodegen generate
```

Worth doing if you iterate: macOS ties the screen-recording permission to
the **code-signing identity**, so ad-hoc builds — which get a fresh identity
every rebuild — are re-prompted for permission each time, and Sequoia is
unreliable about granting ScreenCaptureKit access to them at all. A stable
signing identity keeps the grant.

(No account information is committed to this repository; releases are signed
locally — see [docs/RELEASING.md](docs/RELEASING.md).)

### Versioning

Builds stamp `CFBundleShortVersionString` from `git describe --tags --dirty`, so
every build identifies its exact commit — a clean tag builds as `0.2.0`, three
commits later as `0.2.0-3-gabc1234`, uncommitted changes as `…-dirty`.

## Contributing

Pull requests are welcome and appreciated — that is the whole idea behind the
license below. Bug reports and feature ideas go in
[Issues](https://github.com/kleinzeug/screc/issues).

## License

[MIT](LICENSE) for the source: clone it, build it, change it, ship your fork.
See [LICENSING.md](LICENSING.md) for how that fits together with the paid App
Store build.

Binaries distributed through the Mac App Store are covered by Apple's standard
EULA and sold for a small fee. Buying one is never required — it exists purely
for people who would rather not build from source. If you improve ***screc***,
sending the change back upstream as a pull request is appreciated (a request,
not a condition).

## Support the work

If ***screc*** saves you the QuickTime → crop → ffmpeg ritual often enough to be
worth a coffee:

<a href="https://www.buymeacoffee.com/holzschneider" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" height="50" width="180"></a>
