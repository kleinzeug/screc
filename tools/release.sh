#!/bin/bash
#
# Builds, signs, notarizes and packages a Developer ID release of screc.
#
#   tools/release.sh            # build from the current commit
#   tools/release.sh --skip-notarize   # local dry run, no Apple round-trip
#
# Prerequisites (one-time, see docs/RELEASING.md):
#   • a "Developer ID Application" certificate in the login keychain
#   • DEVELOPMENT_TEAM set in Config/local.xcconfig (gitignored — account
#     information never lives in committed sources; copy the .example)
#   • a notarytool keychain profile named "screc"
#
set -euo pipefail
cd "$(dirname "$0")/.."

SKIP_NOTARIZE=0
[[ "${1:-}" == "--skip-notarize" ]] && SKIP_NOTARIZE=1

APP_NAME="screc"
SCHEME="screc"
DIST="dist"
ARCHIVE="$DIST/$APP_NAME.xcarchive"
EXPORT_DIR="$DIST/export"
APP="$EXPORT_DIR/$APP_NAME.app"
KEYCHAIN_PROFILE="notarization"

step() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$1"; }
fail() { printf '\n\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------- checks
step "Checking prerequisites"

security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application" \
  || fail "No \"Developer ID Application\" certificate found in the keychain.
       Xcode → Settings → Accounts → your team → Manage Certificates… → + → Developer ID Application"

# The team id lives in the gitignored local.xcconfig, never in committed
# sources (xcconfig syntax: DEVELOPMENT_TEAM = TEAMID).
TEAM_ID=$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Za-z0-9][A-Za-z0-9]*\).*$/\1/p' \
  Config/local.xcconfig 2>/dev/null | head -n 1 || true)
[[ -n "$TEAM_ID" ]] || fail "DEVELOPMENT_TEAM is not set in Config/local.xcconfig.
       cp Config/local.xcconfig.example Config/local.xcconfig   # then fill in your team id"

if [[ $SKIP_NOTARIZE -eq 0 ]]; then
  xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1 \
    || fail "No notarytool profile named \"$KEYCHAIN_PROFILE\".
       xcrun notarytool store-credentials $KEYCHAIN_PROFILE \\
         --apple-id <your-apple-id> --team-id $TEAM_ID --password <app-specific-password>"
fi

VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo "0.0.0")
VERSION=${VERSION#v}
[[ "$VERSION" == *-dirty ]] && printf '\033[1;33mwarning:\033[0m working tree is dirty — version will read %s\n' "$VERSION"

# Versions are passed as build settings, never patched into Info.plist after
# the fact: Xcode's plist-processing step can run after script phases and would
# discard the edit (see the note in project.yml).
SHORT_VERSION=$(printf '%s' "$VERSION" | sed -E 's/^([0-9]+(\.[0-9]+){1,2}).*$/\1/')
if ! [[ "$SHORT_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  SHORT_VERSION=$(grep -E '^\s*MARKETING_VERSION:' project.yml | awk '{print $2}')
fi
# Monotonic and bookkeeping-free; strictly increasing per build.
BUILD_NUMBER=$(date -u +%Y%m%d%H%M)
echo "team:    $TEAM_ID"
echo "version: $SHORT_VERSION ($BUILD_NUMBER) — from git describe: $VERSION"

# ---------------------------------------------------------------- build
step "Generating project"
xcodegen generate

step "Archiving (Release)"
rm -rf "$DIST"
mkdir -p "$DIST"
xcodebuild archive \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -destination 'generic/platform=macOS' \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  MARKETING_VERSION="$SHORT_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
  | grep -E "^(===|\*\*|error:|warning: .*deprecat)" || true

[[ -d "$ARCHIVE" ]] || fail "archive not produced"

step "Exporting a Developer ID build"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist Config/ExportOptions.plist \
  | grep -E "^(\*\*|error:)" || true

[[ -d "$APP" ]] || fail "export produced no app bundle"

step "Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "Authority|TeamIdentifier|Timestamp|Runtime" || true

# ---------------------------------------------------------- notarization
ZIP="$DIST/$APP_NAME-$SHORT_VERSION.zip"
step "Packaging for notarization"
ditto -c -k --keepParent "$APP" "$ZIP"

if [[ $SKIP_NOTARIZE -eq 1 ]]; then
  printf '\n\033[1;33mSkipping notarization.\033[0m Unsigned-by-Apple build at %s\n' "$APP"
  exit 0
fi

step "Notarizing (this waits for Apple, usually 1–5 minutes)"
xcrun notarytool submit "$ZIP" --keychain-profile "$KEYCHAIN_PROFILE" --wait

step "Stapling the ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

step "Gatekeeper assessment"
spctl --assess --type execute --verbose=4 "$APP" 2>&1 || fail "Gatekeeper rejected the app"

step "Repackaging the stapled app"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

printf '\n\033[1;32mReady:\033[0m %s\n' "$ZIP"
printf 'A machine that has never seen this app can now open it without warnings.\n'
