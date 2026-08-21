# Mac App Store submission kit

Everything needed for the 1.0.0 submission, prepared so the remaining work is
mechanical. **Nothing here has been submitted.** The two irreversible steps —
uploading a build and pressing *Submit for Review* — are deliberately left to
a human, after hand-QA.

Bundle id `app.screc` · SKU `screc` · category **Video** · price **tier 1**
(one-time, never a subscription) · no in-app purchases · no account required.

---

## 1. Where the pipeline stands

Build pipeline verified end to end; build `202608091147` uploaded, processed
`VALID`, and attached to version 1.0.

| Listing item | State |
|---|---|
| Name, subtitle | ✅ `screc` · `Menu-bar screen recorder` |
| Description, keywords, promotional text | ✅ set via API |
| Support & marketing URL | ✅ `https://screc.app` |
| Privacy policy URL | ✅ `https://screc.app/privacy/` (page published) |
| Screenshots | ✅ 3 × 2560×1600 APP_DESKTOP, all `COMPLETE` |
| Build attached | ✅ 202608091147 |
| Age rating | ✅ 4+ (27 of 29 declarations answered; the two nulls are Kids-Category-only and an optional URL) |
| Pricing | ✅ set |
| App Review contact + notes | ✅ set; demo account explicitly not required |
| Privacy answers (nutrition labels) | ⛔ not exposed by the API — a short form in the UI |
| Submit for Review | ⛔ deliberately human |

**What the API can and cannot do.** Everything above marked ✅ was set through
the App Store Connect API (`tools/`-adjacent scripts under the job scratch
dir). Two things it will not do:

- **Privacy nutrition labels.** `appDataUsages`, `appDataUsageCategories` and
  `apps/{id}/dataUsages` all return "The URL path is not valid" on the current
  API version. Answer *Data Not Collected* in the UI — truthfully, per §3.
- **App Review details** need `contactPhone` in `+<country><number>` form; the
  API rejects empty or local formats. Note the resource is created with
  `demoAccountRequired: true` by DEFAULT — left alone, App Review would expect
  login credentials that screc does not have. It is now explicitly false.

**Two mismatches to decide on:**

- **Category.** App Store Connect says `UTILITIES`. The Mac storefront's
  video category is `PHOTO_AND_VIDEO` (there is no plain "Video"), and the
  bundle's `LSApplicationCategoryType = public.app-category.video` is a
  Launch Services hint in a different namespace — so this is a positioning
  choice, not an inconsistency to repair. Utilities suits a menu-bar tool;
  Photo & Video is topically closer and more competitive. One API call either
  way.
- **Copyright.** The listing reads `2026 Philipp Holzschneider / Kleinzeug`
  (matching LICENSE) while the bundle reads `© 2026 Philipp Holzschneider`.
  Aligning the bundle needs a new build, so the natural moment is the next one.

**Blocked locally:** a fresh build carrying the redrawn small icons cannot be
exported from this machine — the `3rd Party Mac Developer Installer`
certificate is no longer in the keychain and `xcodebuild -exportArchive`
reports "No Accounts". Signing in again under Xcode → Settings → Accounts
restores both. Until then 1.0.0 ships the icons from the 9 August build; the
new small icons would land in the next release.

---

## 2. Listing copy

**Name:** `screc`
**Subtitle (30 char max):** `Menu-bar screen recorder` (24)

**Promotional text (170 max):**
> Record from the menu bar. The share-ready MP4 or GIF exists the moment you
> stop — nothing to export, nothing to convert, nothing to subscribe to.

(145 characters. This is the only listing copy that can change without a new
build, so treat it as a rotating slot.)

**Description** (2405 of 4000 characters):

```
screc records your screen from the menu bar and hands you a file you can send immediately. No export dialog, no ffmpeg incantation, no subscription.

Right-click the red dot to start, click it to stop — the compressed file already exists. Recording is encoded live in H.264 or HEVC at the bitrate you choose, so stopping is instant no matter how long you recorded.

FOUR WAYS TO RECORD
• Focused window — follows focus as you switch windows
• Selected window — one pinned window, or just a region inside it. It survives the window closing and reopening: recording pauses, then resumes as a clean cut instead of frozen video.
• Screen region — drag it out, then nudge the edges and corners. Shift locks the aspect ratio, Option resizes around the centre.
• Full screen — per display

WHILE YOU RECORD
• Live statistics in the menu bar: duration, file size, frame rate, dropped frames
• A dimmed passe-partout shows exactly what is being captured, and follows the window as it moves
• Pause and resume with a modifier-click — a pause becomes a clean cut, not a frozen stretch
• An optional countdown before capture starts

SOUND
• System audio, a microphone, or both — mixed into a single track when you stop
• Pick the input device and its level, with a live input meter while you set it up

SHOW THE INTERACTION
• Draw a magnified cursor, click rings and a scroll indicator into the recording — they appear in the video and never on your own screen, so tutorials show what you did without cluttering your desktop

OUTPUT
• Presets from Tiny MP4 to Master HEVC, plus GIF — every one fully editable: format, resolution cap, frame rate, bitrate, keyframe interval, H.264 profile, CABAC, B-frames, audio bitrate and channels. Save your own.
• GIF conversion on stop, or from any earlier recording, with a built-in frame editor for dropping individual frames — something Preview cannot do
• Global hotkeys for every capture mode, all rebindable
• Recent recordings in the menu: open, delete, reveal in Finder, or convert them

Recordings go to temporary storage by default and clean themselves up after a restart, or choose a folder to keep them in.

Native Swift throughout — ScreenCaptureKit and AVFoundation. No bundled ffmpeg, no Electron, no telemetry, and no network access of any kind.

screc is open source. Building it yourself is free and always will be; this purchase exists for people who would rather not.
```

NOTE: the description deliberately does NOT mention keystroke or shortcut
visualization. Those need Input Monitoring, and whether a sandboxed App Store
build can obtain it is still unverified — advertising it would be a false claim
if it cannot. Once TestFlight settles it, add:

    • Show the keys and shortcuts you press on a translucent on-screen
      keyboard, drawn into the video

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

**`tools/screenshot.sh <name> [delay] [anchor] [display] [size]`** handles that:
it captures the display and crops native pixels to an accepted size — no
scaling, no letterboxing — then flattens any alpha (App Store artwork must be
opaque). The delay leaves time to open a menu or start a recording; menus stay
open while it counts down. Anchors: `topright` (default, where the menu-bar item
is), `topleft`, `top`, `center`. Size defaults to `auto`, the largest accepted
size the display can supply — it prints which one it chose, and **every shot in
a set must use the same size**, so pass it explicitly after the first. Output
lands in `docs/appstore-screenshots/`.

**`tools/frame.sh <movie> [seconds] [anchor] [size]`** does the same job for
shot 5, lifting a still out of a recording.

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
scroll and keys enabled at a native-resolution preset (Master HEVC), then:

```sh
tools/frame.sh /tmp/screc/<recording>.mp4 3 center
```

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
