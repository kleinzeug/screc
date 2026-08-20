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

See [DESIGN.md](DESIGN.md) for the architecture and the research behind it,
and [CHANGELOG.md](CHANGELOG.md) for what each release contains.

## Getting ***screc***

**Build it yourself.** That is the primary way to get ***screc***, it is free, and it
stays free — the source here is complete, with no crippled features and no
paywalled build. Instructions below.

**Or buy it on the Mac App Store** (submission in progress): a small one-time
price for people who would rather not touch a compiler. Never a subscription.
Binaries ship exclusively through the App Store — building from source is,
and stays, the free lane. Nobody who is willing to run `xcodegen generate`
ever needs to pay for this.

## Building

Requirements: **macOS 15+**, **Xcode 16.4+** (what CI builds with; newer
versions work too).

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

macOS also re-confirms this consent periodically for every screen-recording
app — the recurring system prompt is the OS's doing, not ***screc***'s.

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
every rebuild — are re-prompted for permission each time, and recent macOS
versions are unreliable about granting ScreenCaptureKit access to them at all.
A stable signing identity keeps the grant.

Note that `local.xcconfig` is not sufficient on its own. It only names the
team; automatic signing then needs a development certificate **with its
private key** in that machine's keychain, and certificates never travel with
the file. On a new machine, sign in under Xcode → Settings → Accounts (then
*Manage Certificates… → + → Apple Development* if it does not happen by
itself) and build with `-allowProvisioningUpdates`. Otherwise you get:

```
No signing certificate "Mac Development" found: … matching team ID … was found.
```

(No account information is committed to this repository; releases are signed
locally — see [docs/RELEASING.md](docs/RELEASING.md).)

### Versioning

The version comes from the `MARKETING_VERSION` build setting (`1.0.0`), and the
build number from `CURRENT_PROJECT_VERSION`. Release tooling overrides both on
the command line — the version derived from `git describe`, the build number a
UTC timestamp so it always increases:

```sh
xcodebuild … MARKETING_VERSION=1.0.0 CURRENT_PROJECT_VERSION=$(date -u +%Y%m%d%H%M)
```

They are deliberately *not* patched into `Info.plist` by a build phase: Xcode's
plist-processing step can run after script phases, which silently discards the
edit — harmless locally, a rejected upload for a store build.

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
