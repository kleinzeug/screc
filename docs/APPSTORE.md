# Mac App Store submission kit

Everything needed for the 1.0.0 submission, prepared so the remaining work is
mechanical. **Nothing here has been submitted.** The two irreversible steps —
uploading a build and pressing *Submit for Review* — are deliberately left to
a human, after hand-QA.

Bundle id `app.screc` · SKU `screc` · category **Video** · price **tier 1**
(one-time, never a subscription) · no in-app purchases · no account required.

---

## 1. Where the pipeline stands

| Step | State |
|---|---|
| `AppStore` build configuration, sandbox entitlements | ✅ verified |
| Sandbox-aware storage (container tmp + boot purge) | ✅ verified in both flavors |
| Version / build number in the bundle | ✅ 1.0.0 · UTC timestamp |
| Category, export-compliance, copyright, usage strings | ✅ in the built plist |
| `xcodebuild archive -configuration AppStore` | ✅ succeeds |
| `xcodebuild -exportArchive` (signs the .pkg) | ✅ verified 2026-08-09 |
| App Store Connect record, screenshots, listing | ⛔ human (copy ready below) |
| TestFlight pass, Tahoe pass | ⛔ human |
| Upload + Submit for Review | ⛔ deliberately not done |

The whole build pipeline is verified end to end. With the app record in place,
`-allowProvisioningUpdates` created the *Mac Team Store Provisioning Profile:
app.screc* automatically, and the export produced a signed installer:

- `screc.pkg` signed by **3rd Party Mac Developer Installer**
- the app inside it re-signed by **Apple Distribution** (the archive itself is
  signed for development — the export step is what re-signs for distribution)
- hardened runtime on, all four sandbox entitlements present
- 1.0.0 · build `202608091147` · category Video · export-compliance exempt

Only the upload and the review submission remain, and both are deliberately
manual.

---

## 2. Listing copy

**Name:** `screc`
**Subtitle (30 char max):** `Menu-bar screen recorder` (24)

**Promotional text (170 max):**
> One click in the menu bar, and a small, share-ready MP4 or GIF already
> exists when you stop. No export step, no ffmpeg, no subscription.

**Description:**

```
screc records your screen from the menu bar and hands you a file you can
send immediately. No export dialog, no command-line incantation, no
subscription.

Right-click the red dot to start, click to stop — the compressed file is
already on disk. Recording is encoded live in H.264 or HEVC at the bitrate
you choose, so stopping is instant.

FOUR WAYS TO RECORD
• Focused window — follows focus as you switch windows
• Selected window — one pinned window, or a region inside it. It survives
  the window closing and reopening: recording pauses, then resumes as a
  clean cut rather than frozen video.
• Screen region — drag it out, then nudge edges and corners. Hold Shift to
  lock the aspect ratio, Option to resize around the centre.
• Full screen — per display

WHILE YOU RECORD
• Live statistics in the menu bar: duration, size, frame rate, dropped frames
• A dimmed passe-partout shows exactly what is being captured, and follows
  the window
• Pause and resume with a modifier-click; pauses become clean cuts
• Optional countdown before recording starts
• Optionally visualize input: magnified cursor, click rings, scroll wheel,
  keystrokes on a stylized keyboard, and shortcut chips

SOUND
• System audio, the microphone, or both — mixed into one track on stop
• Choose the input device and its level, with a live input meter

OUTPUT
• Presets from Tiny MP4 to Master HEVC, plus GIF — all fully editable:
  format, resolution cap, frame rate, bitrate, keyframe interval, H.264
  profile, CABAC, B-frames, audio bitrate and channels. Save your own.
• GIF conversion on stop or afterwards, with a built-in frame editor for
  dropping individual frames
• Global hotkeys for every mode, all rebindable

Recordings default to temporary storage and clean themselves up after a
restart, or pick a folder to keep them in.

Native Swift throughout — ScreenCaptureKit and AVFoundation. No bundled
ffmpeg, no Electron, no telemetry, no network access. screc is open source;
building it yourself is free and always will be.
```

**Keywords (100 char max, comma-separated, no spaces):**
```
screen recorder,screen capture,record screen,gif,screencast,mp4,capture,demo,tutorial,menubar
```
(94 characters.)

**Support URL:** `https://screc.app` · **Marketing URL:** `https://screc.app`
**Copyright:** `© 2026 Philipp Holzschneider`

---

## 3. Privacy answers

**Data collection: none.** Answer *"Data Not Collected"* for every category —
truthfully: screc makes no network requests at all beyond opening links the
user clicks, has no analytics, no crash reporting, and no accounts. Nothing
leaves the machine; recordings are written to local storage only.

There is no tracking, so the App Tracking Transparency questions do not apply.

**Privacy policy** — required even with no collection. Publish a short page at
`https://screc.app/privacy` stating: screc collects nothing, transmits
nothing, and stores recordings only where the user chooses.

**Age rating:** 4+, no objectionable content.

---

## 4. Review notes (paste into App Review Information)

```
screc is a menu-bar-only utility (LSUIElement) — it intentionally has no
Dock icon and no main window. Its interface is the red ● REC item in the
menu bar on the right side of the screen.

GETTING STARTED
1. On first launch a welcome window appears and asks for Screen Recording
   permission.
2. IMPORTANT: macOS only applies that permission to a freshly launched app.
   After granting it in System Settings, click "Relaunch screc" in the
   welcome window. This relaunch requirement is macOS behavior, not a bug —
   the welcome window explains it. Until then the menu-bar icon shows a
   hollow dot instead of a red one.

HOW TO RECORD
• RIGHT-CLICK the menu-bar item to start recording immediately.
• LEFT-CLICK it for the menu, which lists the four capture modes:
  Focused Window, Selected Window, Screen Region, Full Screen.
• While recording, the item shows live statistics; click it to stop.
  Option-click pauses and resumes instead.
• When recording stops, the finished file appears under "Recent Recordings"
  in the same menu. Click an entry to open it.

OPTIONAL PERMISSIONS — both off by default, and only requested when the
user turns the feature on in Settings:
• Microphone (Settings → Sound → Record Microphone), used only while
  recording, to add voice-over to the recording.
• Input Monitoring (Settings → Input → Show key strokes / key
  combinations), used only while recording, to draw the keys being pressed
  into the recording as a teaching aid. No keystroke is stored, logged or
  transmitted — it is drawn on screen and captured as part of the video.

Screen-recording consent (guideline 2.5.14) is obtained through the system
permission prompt; macOS also shows its own recording indicator, and screc
dims everything outside the captured area while recording, so what is being
captured is always visible.

The app makes no network requests and collects no data.
```

Attaching a 30-second demo video is recommended: menu-bar-only apps are the
most common source of "we could not locate the app's interface" rejections.

---

## 5. Screenshots

Required: at least one, at **2880 × 1800** (16:10); 2560 × 1600, 1440 × 900 and
1280 × 800 are also accepted. Note every accepted size is 16:10 while most Macs
are 16:9, so a full-screen grab is the wrong shape.

**`tools/screenshot.sh <name> [delay] [anchor]`** handles that: it captures the
Retina display and crops 2880 × 1800 of native pixels — no scaling, no
letterboxing — then flattens any alpha (App Store artwork must be opaque). The
delay leaves time to open a menu or start a recording; menus stay open while it
counts down. Anchors: `topright` (default, where the menu-bar item is),
`topleft`, `top`, `center`. Output lands in `docs/appstore-screenshots/`.

The terminal running it needs Screen Recording permission.

Planned set (5):

| # | Shot | Recipe |
|---|---|---|
| 1 | **The menu open** — four capture modes with hotkeys, checkmark on the default | `screenshot.sh menu 6 topright`, then left-click the ● REC and wait |
| 2 | **Recording in progress** — passe-partout dimming everything outside the captured window, live stats in the menu bar | start a Focused Window recording of something recognizable, then `screenshot.sh recording 6 topright` |
| 3 | **Region picker mid-drag** — handles, size readout, floating REC pill | begin Screen Region, drag a rect, `screenshot.sh region 8 top` |
| 4 | **Settings** — preset picker with Format expanded (set the preset to Custom first) | `screenshot.sh settings 6 center` |
| 5 | **Input visualization** — click ring, keyboard HUD, ⌘⇧4 chips | **not a screen capture** — see below |

Shot 5 needs a still lifted **out of a recording**: the decorations are
composited into the video and deliberately never appear on screen, so a
screenshot of the desktop cannot show them. Record full screen with clicks,
scroll and keys enabled at a native-resolution preset, then extract a frame and
crop it to 2880 × 1800.

Captions are optional — Apple provides no caption field for macOS, so any text
has to be baked into the image. Worth considering here precisely because the app
has no main window to speak for itself. Suggested lines: "Four ways to record.
One click each." · "See exactly what you're capturing." · "Drag a region. Nudge
it until it's right." · "Presets, or full control." · "Show clicks and keys for
tutorials."

Shoot on a clean desktop: no personal data, no other apps' content that could
read as third-party branding, and check the ● REC item is actually in frame —
it is the subject of shots 1 and 2.

---

## 6. Pre-submission checklist

- [ ] Hand-QA every feature (the reason this submission is on hold)
- [ ] macOS 26 (Tahoe) pass: menu-bar rendering of the ● REC badge, the
      System Settings deep links, the permission flow
- [ ] Create the app record in App Store Connect: platform macOS, name
      `screc`, primary language English (U.S.), bundle id `app.screc`,
      SKU `screc`. The SKU is internal-only (it appears in sales reports,
      never to customers) and can never be changed — so no version number
      or date in it.
- [ ] Fill in name, subtitle, description, keywords, URLs from §2
- [ ] Privacy answers from §3; publish `screc.app/privacy`
- [ ] Upload the five screenshots from §5
- [ ] Paste the review notes from §4; attach a demo video
- [ ] Archive, export and upload (§7)
- [ ] TestFlight: verify permission flow, sandbox storage, mic, hotkeys on a
      machine that has never run screc
- [ ] Put the real store URL into `BuildFlavor.appStoreURL`
- [ ] Swap the App Store button on screc.app from "planned" to the real link
- [ ] Tag `v1.0.0` and write the GitHub release notes (no binary attached)
- [ ] Submit for review

---

## 7. Build, export, upload

Versions are passed as build settings — never patched into `Info.plist`,
which Xcode may regenerate afterwards (see the note in `project.yml`).

```sh
xcodegen generate
STAMP=$(date -u +%Y%m%d%H%M)

xcodebuild archive \
  -project screc.xcodeproj -scheme screc -configuration AppStore \
  -archivePath dist/screc-appstore.xcarchive \
  -destination 'generic/platform=macOS' \
  MARKETING_VERSION=1.0.0 CURRENT_PROJECT_VERSION="$STAMP" \
  -allowProvisioningUpdates

xcodebuild -exportArchive \
  -archivePath dist/screc-appstore.xcarchive \
  -exportOptionsPlist Config/ExportOptionsAppStore.plist \
  -exportPath dist/appstore \
  -allowProvisioningUpdates
```

The export **signs but does not upload** — `destination` is `export` on
purpose, so no command here can publish by accident. It requires a Mac App
Store provisioning profile, so it only works once the app record exists and
Xcode is signed in to the account (Xcode → Settings → Accounts).

Uploading is a separate, explicit act — either Xcode Organizer → *Distribute
App*, or:

```sh
xcrun altool --upload-app -f dist/appstore/screc.pkg -t macos \
  --apple-id <apple-id> --password <app-specific-password>
```

`CURRENT_PROJECT_VERSION` must be higher than any previously uploaded build;
the UTC timestamp guarantees that without bookkeeping. Bump
`MARKETING_VERSION` in `project.yml` for each new release version.
