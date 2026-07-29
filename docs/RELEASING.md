# Releasing screc

Binaries ship **exclusively through the Mac App Store** (decision of
2026-07-28): source on GitHub for anyone who builds it themselves, the store
build for anyone who would rather pay a small one-time price than compile.
No binaries are attached to GitHub Releases — a free download would defeat
the two-lane model. Updates are handled by the App Store; there is no
in-app updater, deliberately.

Account information never lives in the repository: the team id sits in the
gitignored `Config/local.xcconfig` (copy `Config/local.xcconfig.example`),
and both signing xcconfigs include it optionally.

## App Store release (the release path)

The `AppStore` build configuration carries the sandbox entitlements
(`Config/screc-mas.entitlements`) and Apple Distribution signing
(`Config/appstore.xcconfig`). Store builds sanitize the version to `x.y.z`
and stamp a UTC-timestamp `CFBundleVersion`, so every upload has a strictly
increasing build number with zero bookkeeping.

One-time: an **Apple Distribution** certificate (Xcode → Settings →
Accounts → Manage Certificates), and the app record on App Store Connect
(bundle id `app.screc`).

```sh
git tag v1.0.0                      # the version is stamped from `git describe`
xcodegen generate
xcodebuild archive \
  -project screc.xcodeproj -scheme screc -configuration AppStore \
  -archivePath dist/screc-appstore.xcarchive
xcodebuild -exportArchive \
  -archivePath dist/screc-appstore.xcarchive \
  -exportOptionsPlist Config/ExportOptionsAppStore.plist \
  -exportPath dist/appstore
```

`ExportOptionsAppStore.plist` uploads straight to App Store Connect
(`app-store-connect` / `upload`); Apple's own validation and notarization
run as part of processing. Alternatively archive in Xcode and use the
Organizer. Then: TestFlight pass → submit for review. A GitHub *release*
(tag + notes, **no binary attached**) records which commit each store
version corresponds to.

## Developer ID builds (internal / test builds only)

`tools/release.sh` still produces a signed, notarized, stapled zip — useful
for handing a build to a tester without TestFlight. It is not a
distribution channel.

Prerequisites: a **Developer ID Application** certificate, and a notarytool
keychain profile named `screc`:

```sh
xcrun notarytool store-credentials screc \
  --apple-id you@example.com --team-id YOURTEAMID \
  --password <app-specific password from appleid.apple.com>
```

```sh
tools/release.sh                  # archive → export → notarize → staple → zip
tools/release.sh --skip-notarize  # local dry run, no Apple round-trip
```

## Why keep a stable dev identity (Config/local.xcconfig)

macOS ties the screen-recording permission to the code-signing identity: an
ad-hoc build gets a fresh identity every rebuild and is re-prompted every
time, while a consistent **Apple Development** identity keeps the grant.
Contributors without any Apple account still build ad-hoc out of the box —
that path is what CI exercises.

## Troubleshooting

**"No Developer ID Application certificate found"** — the certificate is
missing or in a different keychain. `security find-identity -v -p codesigning`
should list it.

**Notarization rejected** — ask Apple why:

```sh
xcrun notarytool log <submission-id> --keychain-profile screc
```

**Gatekeeper still warns after stapling** — the quarantine attribute on your
local copy is stale. Test the way a downloader would: unzip a fresh copy in
a different directory, or `xattr -d com.apple.quarantine`.
