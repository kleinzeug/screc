# Changelog

All notable changes to screc. Versions follow [semantic versioning](https://semver.org).

## 1.0.0

First public release.

### Recording

- **Four capture modes**: the focused window (following focus as you switch),
  one specific window (optionally a sub-region inside it), a screen region,
  or a full screen.
- **Live encoding** — H.264 or HEVC at your target bitrate while recording,
  hardware-accelerated. The share-ready file exists the moment you stop;
  there is no export step.
- **A pinned window keeps recording through its own disappearance**: close
  it and recording pauses, reopen a window of the same app and title — even
  after the app itself restarted — and it resumes, with the pause becoming a
  clean cut rather than frozen video.
- **Sub-regions track their window** through moves and resizes.
- **Recording indicator**: a click-through passe-partout dims everything
  except what is being captured, and follows the window.
- Accidental takes under three seconds are discarded automatically
  (configurable).

### Output

- **Presets** from Tiny MP4 to Master HEVC, plus GIF, all fully editable:
  format, max resolution (a cap — smaller content records at native size),
  frame rate, bitrate, keyframe interval, H.264 profile, CABAC, B-frames,
  audio bitrate and channels. Custom presets can be saved, updated and
  deleted.
- **Forced aspect ratio**, which the region picker then enforces while
  dragging.
- **GIF** conversion on stop, or from any recording afterwards, with an
  in-app frame editor for dropping individual frames — something Preview
  cannot do.

### Interface

- Menu-bar only. The **● REC** badge expands into live statistics while
  recording — duration, size, frame rate, dropped frames — in a fixed-width
  layout so the click target never moves.
- **Right-click records, left-click opens the menu.** Each mode entry names
  what it will record ("Screen Region — [400,800]×[200,1000]"); holding ⌥
  switches the entries to the remembered configuration.
- **Global hotkeys**: ⌘⇧8 selected window, ⌘⌥⇧8 focused window, ⌘⇧9 full
  screen, ⌘⌥⇧9 screen region, ⌘⇧0 stop. All rebindable, each clearable back
  to its default.
- **Region picker** with edge and corner handles, L-shaped corner cursors,
  ⇧ to lock the aspect ratio, ⌥ to resize around the centre, live
  coordinates, and a click to start from the whole screen.
- **Recent recordings** in the menu: click to open in QuickTime or Preview,
  ⌘-click to reveal in Finder, ⌥-click to convert to GIF or edit its frames.
  Clear All reports the disk space it frees.
- Configurable storage (`/tmp/screc` by default, so recordings clean
  themselves up on reboot), file-name patterns, launch at login, and a
  notification when a recording is saved.

### Under the hood

- Native Swift throughout — ScreenCaptureKit and AVFoundation, no bundled
  ffmpeg, no Electron.
- Requires macOS 15; builds with Xcode 16.4 or newer.
- Distributed as source (MIT) and as a notarized Developer ID build.
