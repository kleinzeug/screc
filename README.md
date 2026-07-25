# sčrec

A one-click menu-bar screen recorder for macOS that produces small,
share-ready MP4s (or GIFs) with zero post-processing. Pronounced — incorrectly
— "Shrek".

See [DESIGN.md](DESIGN.md) for the full architecture, research findings, and
milestone plan. Current state: **M3** — right-click records (focused window
with follow-focus, a pinned window incl. sub-region that survives window
closes, a screen region, or a full screen), live-encoded to a small
share-ready MP4 in `/tmp/screc`; the GIF preset auto-converts on stop and any
recent MP4 converts via ⌥-click. Recents menu with one-click open in
QuickTime/Preview and Clear All. Polish (M4), Developer ID (M5), and the App
Store variant (M6) are next.

## Building

The Xcode project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
from `project.yml`:

```sh
brew install xcodegen   # once
xcodegen generate
open screc.xcodeproj    # or: xcodebuild -project screc.xcodeproj -scheme screc build
```

Requires Xcode 26+, macOS 15+.

### Signing note (important)

macOS ties the screen-recording permission to the app's code-signing identity.
The project defaults to ad-hoc signing so it builds without any setup, but
ad-hoc builds are re-prompted for permission after every rebuild — and Sequoia
is unreliable about granting ScreenCaptureKit access to them at all. For
day-to-day development: sign into Xcode (Settings → Accounts, a free Apple ID
works), then set `DEVELOPMENT_TEAM` in `project.yml` and remove the
`CODE_SIGN_IDENTITY: "-"` line.
