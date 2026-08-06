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

The full command sequence, the listing copy, the review notes and the
submission checklist live in **[docs/APPSTORE.md](APPSTORE.md)**. In short:

```sh
xcodegen generate
STAMP=$(date -u +%Y%m%d%H%M)
xcodebuild archive -project screc.xcodeproj -scheme screc -configuration AppStore \
  -archivePath dist/screc-appstore.xcarchive -destination 'generic/platform=macOS' \
  MARKETING_VERSION=1.0.0 CURRENT_PROJECT_VERSION="$STAMP" -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath dist/screc-appstore.xcarchive \
  -exportOptionsPlist Config/ExportOptionsAppStore.plist \
  -exportPath dist/appstore -allowProvisioningUpdates
```

Export **signs but never uploads** (`destination` is `export` on purpose).
Uploading is a separate act: Xcode Organizer → *Distribute App*, or
`xcrun altool --upload-app`. Then TestFlight, then submit for review. A GitHub
*release* (tag + notes, **no binary attached**) records which commit each
store version corresponds to.

Versions are passed as build settings, never patched into `Info.plist` after
the fact — Xcode's plist-processing step can run after script phases and
would discard the edit, which for a store build means a wrong
`CFBundleVersion` and a rejected upload.

## Developer ID builds (internal / test builds only)

`tools/release.sh` still produces a signed, notarized, stapled zip — useful
for handing a build to a tester without TestFlight. It is not a
distribution channel.

Prerequisites: a **Developer ID Application** certificate, and a notarytool
keychain profile named `notarization`.

The profile name is deliberately generic rather than per-app: one
app-specific password covers notarization for every Kleinzeug app on this
machine, so revoking or rotating it is a single operation. Create it once:

```sh
xcrun notarytool store-credentials notarization \
  --apple-id you@example.com --team-id YOURTEAMID \
  --password <app-specific password from appleid.apple.com>
```

The password itself is never stored in the repository — it lives in the
login keychain, and only the profile *name* is referenced by
`tools/release.sh`. Generate app-specific passwords at
[appleid.apple.com](https://appleid.apple.com) → Sign-In and Security →
App-Specific Passwords; revoking one there immediately invalidates it, after
which re-running the command above with a fresh password is all that is
needed.

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
xcrun notarytool log <submission-id> --keychain-profile notarization
```

**Gatekeeper still warns after stapling** — the quarantine attribute on your
local copy is stale. Test the way a downloader would: unzip a fresh copy in
a different directory, or `xattr -d com.apple.quarantine`.
