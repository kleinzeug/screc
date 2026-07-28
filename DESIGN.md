# screc — Design & Implementation Plan

*A one-click menu-bar screen recorder for macOS that produces small, share-ready
MP4s (or GIFs) with zero post-processing.*

Researched and written 2026-07-24. Dev machine: macOS 15.7 (Sequoia), Xcode 26.3.

---

## 1. Product definition

The workflow being replaced: QuickTime record → crop → `ffmpeg` downscale/compress
→ share → delete/archive. screc collapses it to:

1. Click the red dot in the menu bar → recording of the frontmost window starts.
2. (Or right-click → record full screen / drag-select a region → floating REC button.)
3. While recording, the status item becomes a stop button + tiny live stats
   (duration · size · fps).
4. Click stop → **the small, share-ready MP4 (or GIF) already exists** — encoding
   happens live during capture, not as a post step.
5. Right-click → recent recordings list → one click opens the file in QuickTime
   (MP4, for trimming) or Preview (GIF). Last menu entry: **Clear All** (deletes
   the files, frees disk).

Storage default is a location that self-destructs on reboot (`/tmp/screc` in the
non-sandboxed build — verified: macOS wipes `/private/tmp` at boot and runs a
daily `tmp_cleaner` daemon).

### Why this is worth building (competitive gap)

No active product ships the full combo *menu-bar one-click → auto-compressed
small MP4 → GIF option → recents menu with clear-all → one-time price*:

- **CleanShot X** ($29, direct-only, not on MAS) is the closest overall — but
  compression is a manual editor step.
- **Gifox 2** ($14.99, closest on the App Store) — GIF-first, editor-mediated.
- **Kap** (19.3k GitHub stars) was the free version of this exact idea — Electron,
  abandoned since Oct 2022. The demand is proven and unclaimed.
- **Built-in Cmd-Shift-5** (macOS 26 even added single-window recording + HEVC
  toggle) still has **no** quality/bitrate/size control, no GIF, no recents
  management. "10-min screencast = 1.4 GB" is a well-documented complaint.
- MAS "screen recorder" search results are dominated by iOS subscription-trap
  ports and low-quality apps with no ratings — an ASO opportunity.

Durable differentiation: **share-ready-by-default output size + GIF + the
recents/clear-all workflow**, not raw capture capability (Tahoe already erodes
that part).

---

## 2. Architecture overview

Pure native Swift. **No ffmpeg** — see §5 for why it adds nothing here.

| Layer | Technology |
|---|---|
| App shell | AppKit lifecycle (`NSApplicationDelegate`); raw `NSStatusItem`; SwiftUI views hosted in AppKit windows |
| Capture | ScreenCaptureKit (`SCStream`, `SCContentFilter`, `SCStreamConfiguration`) |
| Encoding | `AVAssetWriter` live encode (VideoToolbox hardware H.264/HEVC), AAC audio |
| GIF | `AVAssetReader` frame sampling → ImageIO `CGImageDestination` (default) or gifski (licensing decision, §5.3) |
| Settings | SwiftUI `Form.formStyle(.grouped)`, `@AppStorage` |
| Hotkeys | [sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/keyboardshortcuts) (MIT, no extra TCC permission, MAS-safe) |
| Login item | `SMAppService.mainApp` (macOS 13+) |
| Updates (Developer ID build) | Sparkle 2 (MIT) |

**Minimum deployment target: macOS 15.0.** Rationale: dev machine runs 15.7;
macOS 15 shipped Sept 2024; targeting 15 gives ScreenCaptureKit microphone
capture (`captureMicrophone`) so no separate `AVAudioEngine` mic subsystem, plus
`SCRecordingOutput` as a free extra mode. Nothing recording-related was added in
macOS 26 (Tahoe added only a new *screenshot* API), so 15 is the sweet spot.
A macOS 14 backport is possible later (costs: own mic capture + a few
availability checks) — the primary encode path (`AVAssetWriter`) works on 14.

### State machine

One `@MainActor` observable `enum AppState`, shared by the AppDelegate and all
SwiftUI views; every UI surface derives from it:

```
idle ──left-click status item──────────→ recording(.window(frontmost))
idle ──menu "Record Full Screen"──────→ recording(.display)
idle ──menu "Record Region…"──────────→ selecting
selecting ──drag rect + click REC─────→ recording(.region(rect, display))
selecting ──Esc──────────────────────→ idle
recording ──click stop (status item or HUD)──→ finishing   // finalize mp4, optional GIF encode
finishing ──done─────────────────────→ idle  (+ prepend to recents, optional user notification)
```

Transitions drive: status-item icon/title, overlay window lifecycle, floating
panel visibility, and menu item enablement.

---

## 3. App shell (menu bar UX)

Research verdict: SwiftUI's `MenuBarExtra` **cannot** do this UX (no left/right
click distinction, no custom label font, no programmatic control — confirmed
still true in 2026). Use a raw `NSStatusItem` owned by the AppDelegate.

### Status item

- `NSStatusBar.system.statusItem(withLength: .variableLength)` — auto-expands
  when stats text appears.
- **Idle icon**: red `record.circle.fill` SF Symbol rendered non-template
  (`NSImage.SymbolConfiguration(paletteColors:)`, `isTemplate = false`) — colored
  menu-bar icons are allowed; red dot is the recording idiom. ~18×18 pt.
- **Recording**: icon → `stop.fill`; `button.attributedTitle` shows stats in
  `NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)` (monospaced
  digits prevent width jitter), e.g. `0:42 · 12.4 MB · 30fps`, updated by a 1 Hz
  main-thread timer. Single line first; true two-line stats require a custom
  `NSView`/`NSHostingView` subview inside the button (the exelban/stats
  technique, ~7 pt) — an upgrade, not v1.
- **Click routing**: keep `statusItem.menu = nil`;
  `button.sendAction(on: [.leftMouseUp, .rightMouseUp])`; in the action, check
  `NSApp.currentEvent?.type == .rightMouseUp` → temporarily attach the `NSMenu`,
  `button.performClick(nil)`, detach in `menuDidClose` (`popUpMenu` is
  deprecated). Left-click: idle → start frontmost-window recording; recording →
  stop.
- macOS 26 Tahoe notes: menu bar is transparent by default and 30 px tall
  (was 24) — test the red dot on busy wallpapers; there is an open Tahoe bug
  where right-click at the very top pixel misses status items, so Quit/Settings
  must never be right-click-only (also expose ⌃-click / a menu entry while
  recording).

### Right-click menu

```
Record Frontmost Window        ⌥⌘R      (same as left-click)
Record Full Screen             (submenu per display when >1)
Record Region…
──────────────
Output: Small MP4 ▸            (preset quick-switch: Small/Medium/HEVC/GIF)
──────────────
● demo-2026-07-24-1832.mp4  12.4 MB    (thumbnail via item.image, opens QuickTime)
● fix-repro.gif              2.1 MB    (opens Preview)
   … (last 5–10)
Clear All Recordings (frees 84 MB)
──────────────
Settings…
Quit screc
```

Recents rows: plain `NSMenuItem`s with a 16–20 px `item.image` thumbnail — no
custom views in v1 (SwiftUI-in-NSMenuItem has a known leak and loses native
highlighting).

### Region-selection overlay

One borderless `NSWindow` **per screen** (`NSScreen.screens`):
`styleMask: [.borderless]`, `isOpaque = false`, `backgroundColor = .clear`,
`level = .screenSaver`, `collectionBehavior = [.canJoinAllSpaces,
.fullScreenAuxiliary]`, `canBecomeKey` overridden to `true` (Esc must work),
dimmed with 30 % black and the dragged rect punched out via even-odd
`CAShapeLayer`, crosshair cursor via tracking area. On mouse-up, a small
floating panel with the REC button appears at the rect's corner.

**Every screc window sets `sharingType = .none`** so it never appears in the
recording; the capture filter additionally excludes the app
(`SCContentFilter(display:excludingApplications:exceptingWindows:)`) — belt and
suspenders.

### Floating REC/stop panel

`NSPanel` with `[.nonactivatingPanel, .borderless]`, `isFloatingPanel = true`,
`level = .floating`, `becomesKeyOnlyIfNeeded = true`, `collectionBehavior =
[.canJoinAllSpaces, .fullScreenAuxiliary]`, content via `NSHostingView` —
clicking REC/stop never steals focus from the app being recorded.

### Windows (onboarding & settings)

`LSUIElement = YES` (no Dock icon). Windows are AppKit-owned (`NSWindow` +
`NSHostingController` with SwiftUI content) managed by a `WindowManager` — a
menu-bar app cannot reliably present SwiftUI `Window`/`Settings` scenes (see
steipete's 2025 write-up), and menus/status item live in AppKit anyway, so
AppKit owns the lifecycle end-to-end. Presenting uses the activation dance:
`NSApp.setActivationPolicy(.regular)` → `activate()` → `makeKeyAndOrderFront` +
`orderFrontRegardless()` → back to `.accessory` when the last window closes.
First-run detection via a `hasCompletedOnboarding` user default.

Settings panes (Form, grouped style):
- **Recording** — fps (30/60), cursor on/off, system audio on/off, mic on/off + device.
- **Output** — preset (table in §5.2), format MP4/GIF, GIF width/fps.
- **Storage** — `/tmp/screc` (auto-cleared on reboot) / `~/Movies/screc` /
  custom folder; recents list length.
- **General** — launch at login (`SMAppService`), global hotkey (KeyboardShortcuts
  recorder), file-name pattern.

---

## 4. Capture pipeline (ScreenCaptureKit)

### Three capture modes

1. **Frontmost window** (the one-click path):
   - `pid = NSWorkspace.shared.frontmostApplication?.processIdentifier`
   - `SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)`
   - filter windows: `owningApplication?.processID == pid`, `windowLayer == 0`
     (normal-window layer), `isOnScreen`, plausible frame (> 40 pt), non-empty
     title — this drops menu-bar items and borderless junk.
   - True z-order within the layer: cross-reference
     `CGWindowListCopyWindowInfo([.optionOnScreenOnly], …)` (front-to-back order)
     matching `kCGWindowNumber` ↔ `SCWindow.windowID`. (`SCShareableContent.windows`
     order is undocumented — don't rely on it.)
   - Wrap in `SCContentFilter(desktopIndependentWindow:)` — follows the window
     across Spaces/displays, captures full window bounds.
2. **Full display**: `SCContentFilter(display:excludingApplications: [self], exceptingWindows: [])`;
   `includeMenuBar` toggle (14.2+).
3. **Region**: display filter + `config.sourceRect` — **display-local points,
   top-left origin** → flip Y from AppKit's bottom-left rects
   (`newY = screen.frame.height - rect.height - rect.origin.y`). Output size:
   `config.width/height = rect × filter.pointPixelScale`, **rounded to even**
   (H.264 dislikes odd dimensions).

### Stream configuration

- `minimumFrameInterval = CMTime(value: 1, timescale: 30)` (or 60). SCK is
  damage-driven — frames arrive only when content changes; fps is a cap.
- `queueDepth = 5` (up to 8 for 60 fps); buffers are IOSurface-backed from a
  fixed pool — release promptly or delivery stalls.
- `showsCursor` per settings; `ignoreShadowsSingleWindow = true` for tight
  window crops.
- Downscaling happens **on the GPU at capture time**: set `width`/`height` to
  the preset's target (e.g. cap long edge at 1280 px) — this is what makes the
  ffmpeg step unnecessary. `captureResolutionType = .nominal` records at points
  (1×) instead of 2× Retina pixels when the preset wants small output.
- Audio: `capturesAudio = true`, `excludesCurrentProcessAudio = true`, 48 kHz
  stereo (rides on the screen-recording permission — no extra TCC). Mic:
  `captureMicrophone = true` + `microphoneCaptureDeviceID` (macOS 15+, needs
  Microphone TCC + `NSMicrophoneUsageDescription`).

### Live statistics (the expanded status item)

There is **no** delivered/dropped-frame counter API; compute stats ourselves in
the `.screen` stream-output callback:

- **fps**: count frames with attachment `SCStreamFrameInfo.status == .complete`
  per second (skip `.idle`/`.blank`).
- **dropped**: count appends skipped because `AVAssetWriterInput
  .isReadyForMoreMediaData == false`.
- **duration**: wall clock since first appended frame.
- **size / bitrate**: bytes written to the output file
  (`FileManager.attributesOfItem`) polled at 1 Hz; bitrate = Δsize × 8.

### Stopping cleanly

`stream.stopCapture()` → `input.markAsFinished()` →
`writer.endSession(atSourceTime: lastPTS)` → `await writer.finishWriting()` —
only then is the moov atom written and the file playable; never surface the file
before this completes. Implement `SCStreamDelegate.stream(_:didStopWithError:)` —
it fires when the captured window closes, the user stops from the system's
purple menu-bar indicator, or the system kills the stream — treat as "finalize
now, then explain" using `SCStreamError.Code` (`.userStopped`,
`.noCaptureSource`, …). Pad idle gaps by repeating the last frame so video
duration matches wall time (Nonstrict's technique). Note: macOS always shows its
own purple capture indicator during recording; it cannot be suppressed.

---

## 5. Encoding pipeline

### 5.1 Why no ffmpeg

- The primary output is produced **live** by `AVAssetWriter`
  (hardware-accelerated by default via VideoToolbox on Apple Silicon) with full
  bitrate control — the exact knob QuickTime lacks and the reason ffmpeg was in
  the loop.
- An App-Store-legal ffmpeg would have to be an LGPL build **without x264**, so
  it would use `h264_videotoolbox` — the same encoder AVAssetWriter already
  uses. GPL builds (with x264) are a hard no on MAS. Bundling buys ~nothing and
  costs 25–70 MB + licensing risk.
- What native-only gives up: x264 quality below ~500 kbps, 2-pass ABR, WebM/AV1,
  and ffmpeg `palettegen` GIF quality (recoverable via gifski). None matter here.

`SCRecordingOutput` (macOS 15's zero-code record-to-file) was evaluated and
**rejected as the primary path**: its configuration is only
`outputURL`/`videoCodecType`/`outputFileType` — **no bitrate control**, and the
default encode is reported visibly low-bitrate. It may return later as a
"quality doesn't matter, just record" bonus mode.

### 5.2 Live MP4 encode

`AVAssetWriterInput` with `expectsMediaDataInRealTime = true` and:

```swift
AVVideoCodecKey: .h264,
AVVideoCompressionPropertiesKey: [
    AVVideoAverageBitRateKey: preset.bitrate,
    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
    AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
    AVVideoExpectedSourceFrameRateKey: fps,
    AVVideoMaxKeyFrameIntervalKey: fps * 4,   // 4 s GOP — big win for mostly-static screen content
]
```

**Presets** (screen content is mostly static; average-bitrate goes far):

| Preset | Long edge | fps | Codec | Video bitrate | Audio | ≈ size |
|---|---|---|---|---|---|---|
| **Small MP4** (default) | 1280 px | 30 | H.264 High CABAC | 1.2 Mbps (floor 800 kbps) | AAC 96 kbps mono | ~9 MB/min |
| Medium MP4 | 1920 px | 30 (60 opt.) | H.264 | 3 Mbps (5 @ 60) | AAC 128 kbps | ~22 MB/min |
| Compact HEVC (opt-in) | 1920 px | 30 | HEVC Main | 1.5–2 Mbps | AAC 128 kbps | ~60 % of H.264 |
| Master (opt-in) | native 2× | 60 | HEVC | 8–10 Mbps | AAC 128 kbps | for later re-export |
| GIF | 640 px (max 800) | 12 (10–15) | GIF ∞-loop | — | — | suggest ≤ 15 s |

Default is H.264: HEVC needs a paid codec extension on Windows and previews
unreliably in Slack/older browsers. HEVC gets written with the correct `hvc1`
tag by AVFoundation when chosen.

### 5.3 GIF path

Record MP4 as above, then transcode (this also enables "make a GIF from an
existing recording" retroactively):

- **Frame extraction: `AVAssetReader`** + `copyNextSampleBuffer()`, keeping
  frames whose PTS crosses each 1/12-s boundary. (**Not**
  `AVAssetImageGenerator` — slow, got ~3× slower in the iOS 17-era OSes, throws
  random decode errors; the Gifski project itself migrated away from it.)
- **Encoder, two options**:
  - *Default:* ImageIO `CGImageDestination` (`kCGImagePropertyGIFDelayTime` +
    `GIFLoopCount 0`). Zero dependencies, App-Store-clean; per-frame 256-color
    quantization with no palette/dither control — fine for flat-color UI
    content, weaker on gradients/video.
  - *Quality upgrade:* the **gifski** library (cross-frame palettes, temporal
    dithering — the benchmark). **License: AGPL-3.0-or-later, or a paid
    commercial license** (gif.ski/license.html). Shipping it closed-source
    requires buying the license; open-sourcing screc (AGPL-compatible) is the
    free path. Decision deferred; the encoder sits behind a `GIFEncoder`
    protocol so it's a drop-in later.

### 5.4 Post-processing extras (later)

- "Re-compress / resize existing recording": same `AVAssetReader` →
  `AVAssetWriter` transcode with arbitrary settings (the
  SDAVAssetExportSession pattern, MIT). `AVAssetExportSession` is useless here —
  fixed presets, no bitrate control.
- Spatial crop after the fact: `AVMutableVideoComposition` with `renderSize` +
  layer-instruction transform (region capture makes this rarely needed).
- **GIF frame editing must live in screc**: research falsified the plan to hand
  GIFs to Preview for frame deletion — Preview can only *view* frames and export
  a single one; it cannot delete frames and re-save. A simple thumbnail-strip
  "drop frames / re-encode" sheet fed by the kept mp4 frames is the replacement
  (cheap with the pipeline above).

### 5.5 Viewer handoff

- MP4 → QuickTime Player:
  `NSWorkspace.shared.open([url], withApplicationAt: qtURL, configuration: …)`
  with `urlForApplication(withBundleIdentifier: "com.apple.QuickTimePlayerX")`
  (the trailing X is historical and correct); fall back to plain `open(url)`.
  Good news for the trim workflow: QuickTime **Trim + Save is lossless
  passthrough** (no re-encode), so trimming screc's already-compressed file
  doesn't degrade it. "Export As" would re-encode — users should just Save.
- GIF → Preview (`com.apple.Preview`) for viewing; frame editing in-app (§5.4).
- "Reveal in Finder": `NSWorkspace.shared.activateFileViewerSelecting([url])`.

---

## 6. Permissions & onboarding

Screen recording is **pure TCC** (no entitlement exists). Key facts:

- `CGPreflightScreenCaptureAccess()` = silent check;
  `CGRequestScreenCaptureAccess()` prompts **once ever** while undetermined;
  after a denial only the user can flip the toggle in System Settings.
- **A relaunch is required after granting** — the running process keeps the
  stale verdict (DTS-confirmed, all of 14/15/26). Onboarding flow:
  request → poll preflight → offer "Relaunch screc" (spawn new instance via
  `open -n`, terminate).
- Deep-link button (verified working on this machine, 15.7.4):
  `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`
- **Sequoia monthly nag** ("allow for one month"): since 15.1, `replayd`
  refreshes the timestamp on every use, so a regularly used recorder
  effectively never re-nags; only after ~30 days of disuse. Accept it; do not
  ship plist tampering. The `persistent-content-capture` entitlement is
  Apple-gated for VNC-class apps — not obtainable.
- `SCContentSharingPicker` (system picker) would avoid TCC entirely **but
  cannot do one-click frontmost-window or drag-region capture** — it
  contradicts the core UX, so classic TCC is the primary path. The picker may
  be added later as an optional privacy mode.
- Mic (only if enabled): `com.apple.security.device.audio-input` (sandbox) +
  `NSMicrophoneUsageDescription`. `NSScreenCaptureUsageDescription` is **not a
  real key** (circulates in cross-platform templates) — omit.
- Dev annoyance fix: sign Debug builds with an **Apple Development** cert +
  stable bundle id (never ad-hoc) — otherwise every rebuild re-prompts TCC, and
  Sequoia effectively refuses SCK for ad-hoc binaries.

Onboarding window (first run): welcome → permission card with live status
(red/green), "Open System Settings" deep-link button, "Relaunch" button →
defaults card (preset, storage, hotkey) → done, retreat to menu bar.

---

## 7. Storage & recents

`RecordingStore` protocol isolating location strategy (the sandbox fork point):

| Build | Default location | Reboot-clean guarantee |
|---|---|---|
| Local / Developer ID (no sandbox) | `/tmp/screc` | OS-provided: boot wipe + daily `tmp_cleaner` (verified on 15.7) |
| Mac App Store (sandboxed) | container `Data/tmp/` | **DIY**: on each launch purge files older than last boot (`sysctl kern.boottime`) — the OS does *not* reliably clean container tmp (DTS-confirmed) |
| Both | user-chosen folder (`~/Movies/screc` etc.) | none (persistent); MAS via NSOpenPanel + security-scoped bookmark |

Writing to real `/tmp` from the sandbox requires a temporary-exception
entitlement that App Review rejects in practice — hence the dual strategy.

Recents: array of `{url, date, size, kind, thumbnail}` in UserDefaults
(validated against disk at menu-build time; entries whose file vanished are
dropped). **Clear All** deletes files + entries and shows the freed bytes in its
title before clicking.

---

## 8. Distribution roadmap

Bundle id fixed from day one (TCC grants and the MAS container key off it):
`com.<yourdomain>.screc`, `PRODUCT_NAME`/`CFBundleName` ASCII **screc** (diacritics
in bundle/product names break signing tooling), display name **screc** in
`CFBundleDisplayName` / App Store listing only. Two entitlement files from day
one (`screc-dev.entitlements` without sandbox, `screc-mas.entitlements` with),
wired per build configuration — forces sandbox-clean file handling into the
design instead of a retrofit.

### Stage 1 — local Xcode build (now; free account suffices)
- LSUIElement menu-bar app, Debug signed with Apple Development cert.
- Full feature set incl. `/tmp/screc` storage.
- Hardened runtime on (harmless locally, required later anyway).

### Stage 2 — Developer ID (first shareable build)
- Apple Developer Program ($99/yr) → Developer ID Application cert.
- Hardened runtime + `xcrun notarytool submit --wait` + `xcrun stapler staple`;
  ship zip/DMG; add Sparkle 2 for updates.
- Storage default stays `/tmp/screc`.

### Stage 3 — Mac App Store
- Swap to sandbox entitlements: `app-sandbox`,
  `files.user-selected.read-write`, `files.bookmarks.app-scope`,
  `device.audio-input` (if mic). Remove Sparkle. No temporary exceptions.
- Storage default → container tmp + boot-aware purge.
- Review guidelines in play: 2.4.5(i) sandbox, **2.5.14** explicit consent +
  visible recording indication (status-item stop button + system purple
  indicator satisfy this), 5.1.1 privacy, 2.3.7 unique name.
- Beta via TestFlight for Mac.

---

## 9. Naming check (⚠ decide before Stage 2)

The string "screc" is crowded:
- **ScRec** — existing Android *screen recorder* (`com.enoiu.screc`), same name,
  same category.
- **ScreenRec** — established free recorder (screenrec.com) **and** a late-2025
  Mac App Store recorder literally named ScreenRec — one typo away in-store.
- **scrcpy** (100k-star Android mirroring tool) — big developer mindshare nearby.
- GitHub `lvzhenbo/screc` is an actively maintained adult-cam-stream ripper —
  awkward "screc github" search results.
- Domains: screc.com/org taken; **screc.app appeared unregistered** (verify).
- Shrek pun: the spelling is distant and the field of goods differs — low risk —
  but DreamWorks' SHREK registration covers software, so never lean on the
  association in marketing (no ogre-green branding, no "pronounced Shrek"
  tagline in store copy). Keep the joke in the README, not the listing.
- Diacritic display names are allowed on the App Store (30-char limit; search
  normalizes accents).

Options: keep screc (accept adjacency, own the .app domain), or pick a more
distinctive name before public release. **Recommendation: keep it for Stages
0–1; revisit before Developer ID release.**

**DECIDED (2026-07-26): the name is screc.** The screc.app domain is
registered to the author, which anchors the claim; the Android "ScRec"
adjacency is accepted knowingly (different platform). Bundle id switched to
`app.screc` while still pre-release (UserDefaults migrated); this is final.

**DECIDED (2026-07-26): diacritic branding retired.** The "sčrec" stylization
and the Shrek pronunciation joke are dropped for a sober, sleek identity:
plain lowercase **screc** everywhere (UI, site, docs). The landing page lives
in `docs/` (GitHub Pages layout) with a CNAME for screc.app.

### Pricing (from the survey, for later)
Active quality-tier competitors cluster at **$15–30 one-time** (Gifox 14.99,
Omi 19.99, CleanShot 29). Positioning that undercuts everything while matching
willingness-to-pay: free or ~$10–15 one-time, **no artificial time caps** —
differentiate on convenience, not limits.

---

## 10. Milestones

- **M0 — scaffold** ✅ (2026-07-24): Xcode project (XcodeGen), LSUIElement, two
  entitlement files, status item + state machine, onboarding window with TCC
  flow (deep link + relaunch). Note: ad-hoc signed until an Apple Development
  cert is configured.
- **M1 — core loop** ✅ (2026-07-24): frontmost-window detection → SCStream →
  AVAssetWriter (all presets incl. audio) → stop → file in `/tmp/screc` →
  recents menu → open in QuickTime. Full-screen recording (per-display submenu)
  shipped early since the engine is target-generic. Idle-gap heartbeat padding
  implemented.
- **M2 — capture modes** ✅ (2026-07-24): region overlay with drag-select
  (per-screen dim windows, punch-out, size readout, Esc/Enter) + floating
  non-activating REC panel; all selection windows `sharingType = .none` and the
  region filter excludes the app. Full-screen had already shipped in M1.
- **M2.5 — UX refinements** ✅ (2026-07-24, user feedback after testing):
  click-through recording passe-partout (dim + red-bordered hole over what's
  captured) for region *and* window recordings; window mode follows focus —
  a `CGWindowList` poller (no Accessibility permission) tracks the focused
  window's frame for the overlay and retargets the live stream via
  `updateContentFilter` when focus changes; "Record Focused Window" semantics
  (frontmost app's top layer-0 window, never stay-on-top panels); left-click
  repeats the last-used capture mode (persisted, checkmarked in the menu);
  stats render left of the icon (`imageTrailing` — status items grow leftward,
  so the start/stop click target never moves); icon set: hollow monochrome ring
  (no permission) → ring + red dot (ready) → ring + monochrome stop square
  (recording), custom-drawn so the ring adapts to the menu bar while the dot
  stays red.
- **M2.6 — second feedback round** ✅ (2026-07-25): stronger passe-partout dim
  (45 %), no border; splash/settings truly centered; "About screc…" menu item;
  **click roles swapped** (left = menu, right = record/stop); fixed-width
  stats via figure-space padding; preset resolution confirmed as max-only
  (native size when smaller, never upscaled); new **"Record Specific
  Window…"** pinned mode — screenshot-style hover pick (light-blue highlight,
  camera cursor), single click + adjustable capture boundary inside the
  window (normalized to window origin/size, tracks moves & scales with
  resizes), records via display filter compositing ONLY that window +
  live-updated `sourceRect`; window closed → recording pauses (PTS retiming
  makes pauses clean cuts); same-app-same-title window reappearing (even
  after process restart) → recording resumes and retargets.
- **M3 — GIF** ✅ (2026-07-25): native GIF pipeline (AVAssetReader with
  decode-time downscaling → ImageIO, PTS-sampled to the target fps, ∞ loop) —
  verified end-to-end: 3 s test movie → exactly 36 frames @12 fps in 0.27 s.
  GIF preset auto-converts on stop (MP4 master deleted after success);
  ⌥-clicking a recent MP4 converts it (GIF entries get ⌥ → Reveal in Finder);
  GIF width (480/640/800) + fps (10/12/15) in Settings. gifski upgrade path
  still open behind the converter seam (licensing decision, §5.3). Live
  stats/Clear All had already shipped in M1–M2.5.
- **M3.5 — preset system** ✅ (2026-07-25): settings rebuilt around a
  `RecordingConfig` value type (format MP4/HEVC/GIF; max width+height caps —
  native/aspect decides actual; max fps; bitrate; audio bitrate; advanced:
  keyframe interval, CABAC; GIF: loop, CIDither intensity). Preset picker
  derives selection by config-matching — any edit flips it to "Custom" and
  reveals a name field + "Save as Preset" (duplicates allowed, persisted in
  UserDefaults). Engine + GIF converter consume the config directly; old
  preset-id defaults migrate. Dither verified (and documented: noise defeats
  GIF RLE — 33 KB → 163 KB on the test clip — hence default off).
- **M4 — polish** ✅ (2026-07-26): storage location picker (/tmp · ~/Movies ·
  custom via NSOpenPanel) + file-name pattern with {date}/{time} tokens;
  global start/stop hotkey (sindresorhus/KeyboardShortcuts SPM, MIT, no extra
  TCC); launch at login (SMAppService); "Recording saved" notification with
  click-to-open (UNUserNotificationCenter); system-initiated stop
  classification (.userStopped silent, others explained after saving);
  in-app GIF frame-strip editor (⌥ recents entry → thumbnail grid, click to
  mark frames, atomic in-place rewrite preserving delays/loop — verified:
  36 → 18 frames round-trip). Version 0.2.0.
- **M7 — public presentation** ✅ (2026-07-27, pulled ahead of M5 by design:
  the decision to pay for a developer account depended on the app presenting
  convincingly):
  landing page (site/index.html — self-contained, brand colors sampled from
  the icon, drawn menu-bar hero, live stats ticker, dual-theme), App Store
  asset checklist (screenshots 2880×1800/2560×1600/1440×900/1280×800, 1024
  icon ✅, description, keywords, privacy labels), and the identity decisions:
  final app name (see §9 collisions), public author vs. team/label name,
  domain (screc.app looked unregistered), support e-mail, pricing.
- **M5 — Developer ID release** (in progress, 2026-07-28): signing and export
  verified end to end — Developer ID certificate, hardened runtime, secure
  timestamp; `tools/release.sh` archives → exports → notarizes → staples →
  Gatekeeper-checks → packages, documented in docs/RELEASING.md. Account
  information is kept out of the repository via an optional-include xcconfig.
  Outstanding: notarytool credentials (needs an app-specific password), the
  first notarized build, and auto-updates (Sparkle) before there are users to
  strand.
- **M6 — Mac App Store**: sandbox storage variant, bookmark-based custom
  folders, review prep (2.5.14 consent copy), TestFlight beta, listing
  (screenshots, ASO against the subscription-trap field).

## 11. Risks & open questions

1. **GIF quality vs license**: ImageIO output on gradient-heavy content may
   disappoint; gifski needs a commercial license or an AGPL screc. Defer behind
   `GIFEncoder` protocol; decide at M3 with real output samples.
2. **Name collision** (§9) — decide before anything public.
3. **Tahoe verification pass**: transparent 30 px menu bar rendering, the
   top-pixel right-click bug, deep-link URL, nag cadence — needs a macOS 26 VM
   (dev machine is 15.7; Xcode 26.3 builds with the 26 SDK but can't run
   Tahoe-only behavior).
4. **Two-line stats** in the status item requires the custom-view technique —
   v1 ships single-line; evaluate legibility in practice.
5. **Frontmost-window heuristics**: layer-0 + z-order filtering is the
   community-standard approach but has edge cases (palettes, sheets, PWAs) —
   budget tuning time in M1.
6. **Idle-frame padding**: SCK's damage-driven delivery means a static screen
   yields no frames; the writer path must repeat last frames or the duration
   collapses — core correctness item in M1, easy to get subtly wrong.

## 12. Key references

- Apple: [Capturing screen content in macOS](https://developer.apple.com/documentation/ScreenCaptureKit/capturing-screen-content-in-macos) · [SCStreamConfiguration](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration) · [SCRecordingOutput](https://developer.apple.com/documentation/screencapturekit/screcordingoutput) · [Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) · [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- Nonstrict: [Recording to disk with ScreenCaptureKit](https://nonstrict.eu/blog/2023/recording-to-disk-with-screencapturekit/) + [MIT example repo](https://github.com/nonstrict-hq/ScreenCaptureKit-Recording-example) — safe to borrow from.
- OSS to read (licenses noted): [QuickRecorder](https://github.com/lihaoyun6/QuickRecorder) (AGPL — read, don't copy), [Azayaka](https://github.com/Mnpn/Azayaka) (no license — read only), [Gifski.app](https://github.com/sindresorhus/Gifski) (MIT app / AGPL lib), [SDAVAssetExportSession](https://github.com/rs/SDAVAssetExportSession) (MIT), [exelban/stats](https://github.com/exelban/stats) (two-line status item), [KeyboardShortcuts](https://github.com/sindresorhus/keyboardshortcuts) (MIT).
- steipete: [Showing Settings from macOS Menu Bar Items](https://steipete.me/posts/2025/showing-settings-from-macos-menu-bar-items)
- Sequoia nag mechanics: [mjtsai roundup](https://mjtsai.com/blog/2024/08/08/sequoia-screen-recording-prompts-and-the-persistent-content-capture-entitlement/) · [MacRumors on 15.1 softening](https://www.macrumors.com/2024/10/07/apple-screen-recording-popup-update/)
