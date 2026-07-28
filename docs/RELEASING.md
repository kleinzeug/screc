# Releasing screc

Direct-download builds are signed with a **Developer ID Application**
certificate and notarized by Apple, so Gatekeeper opens them without the
"unidentified developer" warning. Everything after the one-time setup is a
single command.

## One-time setup

### 1. Certificates

Xcode → **Settings → Accounts** → **+** → sign in with the Apple ID that
holds the Developer Program membership. Select the team → **Manage
Certificates…** → **+** and create both:

- **Apple Development** — for everyday builds. Worth having on its own: the
  screen-recording permission is tied to the signing identity, so an
  ad-hoc-signed build asks for it again after every rebuild, while a
  consistently signed one does not.
- **Developer ID Application** — for distribution.

Note the **Team ID** (Xcode shows it next to the team name; it also appears
at developer.apple.com → Membership).

### 2. Point the build at your team

Account information stays out of the repository. Copy the example and fill
in your team id — the file is gitignored:

```sh
cp Config/local.xcconfig.example Config/local.xcconfig
$EDITOR Config/local.xcconfig      # DEVELOPMENT_TEAM = YOURTEAMID
xcodegen generate
```

`Config/signing.xcconfig` includes it optionally, so a clone without it
still builds (ad-hoc). `tools/release.sh` reads the team id from the same
file.

### 3. Notarization credentials

Notarization needs an **app-specific password**, not your Apple ID password.
Create one at [appleid.apple.com](https://appleid.apple.com) → Sign-In and
Security → App-Specific Passwords. Then store it once in the keychain:

```sh
xcrun notarytool store-credentials screc \
  --apple-id you@example.com \
  --team-id YOURTEAMID \
  --password abcd-efgh-ijkl-mnop
```

The profile name `screc` is what `tools/release.sh` looks for.

## Cutting a release

```sh
git tag v0.3.0            # the version is stamped from `git describe`
tools/release.sh
```

The script archives a Release build, exports it with the Developer ID
certificate (hardened runtime, secure timestamp), verifies the signature,
submits it to Apple and waits, staples the ticket to the app, asks
Gatekeeper for a verdict, and leaves `dist/screc-<version>.zip` ready to
upload.

`tools/release.sh --skip-notarize` does everything except the Apple
round-trip — useful for checking that signing and export work.

## Publishing

Attach the zip to a GitHub release on the tag:

```sh
gh release create v0.3.0 dist/screc-0.3.0.zip \
  --title "screc 0.3.0" --notes "…"
```

Then update the download link on [screc.app](https://screc.app).

## Troubleshooting

**"No Developer ID Application certificate found"** — the certificate is
missing or in a different keychain. `security find-identity -v -p codesigning`
should list it.

**Notarization rejected** — ask Apple why:

```sh
xcrun notarytool log <submission-id> --keychain-profile screc
```

The usual causes are a missing hardened runtime, a missing secure timestamp,
or an embedded binary that is not signed — the script sets the first two and
Xcode signs the one bundled framework.

**Gatekeeper still warns after stapling** — the quarantine attribute on your
local copy is stale. Test the way a downloader would: unzip a fresh copy in
a different directory, or `xattr -d com.apple.quarantine`.
