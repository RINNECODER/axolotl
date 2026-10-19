#!/bin/bash
# Build, sign (Developer ID), notarize and publish an Axolotl release that Sparkle picks up.
#   ./scripts/release.sh 1.0.3
# Publishes the zip + appcast.xml to https://github.com/RINNECODER/axolotl-releases (binaries only).
set -euo pipefail

VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || { echo "usage: $0 <version>   e.g. $0 1.0.3" >&2; exit 64; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
RELEASES_REPO="RINNECODER/axolotl-releases"
NOTARY_PROFILE="axolotl-notary"
SPARKLE_ACCOUNT="axolotl" # Keychain account holding the EdDSA private key (generate_keys --account axolotl)
WORK="${TMPDIR:-/tmp}/axolotl-release-$VERSION"

die() { echo "error: $*" >&2; exit 1; }

# --- Preflight -------------------------------------------------------------
command -v xcodegen >/dev/null || die "xcodegen not found (brew install xcodegen)"
command -v gh >/dev/null && gh auth status >/dev/null 2>&1 || die "gh is not installed or not signed in (gh auth login)"
TEAM="$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Z0-9]*\).*/\1/p' Signing.xcconfig 2>/dev/null | head -1)"
[[ -n "$TEAM" ]] || die "set DEVELOPMENT_TEAM in Signing.xcconfig (see README › Build from source)"
# Notarization is optional: without the profile the release is Developer ID-signed only
# (first download needs right-click → Open; Sparkle updates install without prompts).
NOTARIZE=0
if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then NOTARIZE=1
else echo "note: no notary profile '$NOTARY_PROFILE' — skipping notarization (see README › Releasing to enable)"; fi
gh release view "v$VERSION" -R "$RELEASES_REPO" >/dev/null 2>&1 && die "v$VERSION is already released on $RELEASES_REPO"

rm -rf "$WORK" && mkdir -p "$WORK/releases"

# --- Version bump ----------------------------------------------------------
BUILD=$(( $(sed -n 's/^ *CURRENT_PROJECT_VERSION: *\([0-9]*\).*/\1/p' project.yml | head -1) + 1 ))
sed -i '' -E "s/^( *MARKETING_VERSION: ).*/\1\"$VERSION\"/; s/^( *CURRENT_PROJECT_VERSION: ).*/\1$BUILD/" project.yml
echo "==> Axolotl $VERSION ($BUILD)"
xcodegen generate >/dev/null

# --- Archive + export (Developer ID; Xcode's cloud-managed cert works via -allowProvisioningUpdates) --
echo "==> Archiving (log: $WORK/archive.log)"
xcodebuild archive -project Axolotl.xcodeproj -scheme Axolotl -configuration Release \
  -archivePath "$WORK/Axolotl.xcarchive" -clonedSourcePackagesDirPath "$WORK/spm" \
  -allowProvisioningUpdates >"$WORK/archive.log" 2>&1 || { tail -20 "$WORK/archive.log"; die "archive failed"; }

SPARKLE_BIN="$WORK/spm/artifacts/sparkle/Sparkle/bin"
"$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p >/dev/null 2>&1 || die "no Sparkle EdDSA key '$SPARKLE_ACCOUNT' in the login Keychain.
Restore it with: $SPARKLE_BIN/generate_keys --account $SPARKLE_ACCOUNT -f <exported-private-key-file>
(a NEW key would not match SUPublicEDKey in Axolotl/Sparkle-Info.plist, and installed copies would reject updates)."

cat >"$WORK/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM</string>
</dict></plist>
EOF
echo "==> Exporting with Developer ID"
xcodebuild -exportArchive -archivePath "$WORK/Axolotl.xcarchive" -exportPath "$WORK/export" \
  -exportOptionsPlist "$WORK/ExportOptions.plist" -allowProvisioningUpdates >"$WORK/export.log" 2>&1 || {
  tail -20 "$WORK/export.log"
  die "Developer ID export failed. One-time setup: Xcode › Settings › Accounts › (your team) › Manage Certificates › + › Developer ID Application (needs the Account Holder role), then rerun."
}
APP="$WORK/export/Axolotl.app"

# --- Notarize + staple -------------------------------------------------------
ZIP="$WORK/releases/Axolotl-$VERSION.zip"
[[ $NOTARIZE == 1 ]] && ditto -c -k --keepParent "$APP" "$WORK/notarize.zip"
if [[ $NOTARIZE == 1 ]]; then
  echo "==> Notarizing (takes a few minutes)"
  xcrun notarytool submit "$WORK/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait | tee "$WORK/notary.log"
  grep -q "status: Accepted" "$WORK/notary.log" || die "notarization was not accepted (see: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE)"
  xcrun stapler staple "$APP"
fi
ditto -c -k --keepParent "$APP" "$ZIP"

# --- Appcast (EdDSA-signed with the Keychain key) + publish -----------------
# The feed is releases/latest/download/appcast.xml, so each release carries an appcast with its own item.
"$SPARKLE_BIN/generate_appcast" --account "$SPARKLE_ACCOUNT" \
  --download-url-prefix "https://github.com/$RELEASES_REPO/releases/download/v$VERSION/" "$WORK/releases"
grep -q "sparkle:edSignature" "$WORK/releases/appcast.xml" || die "appcast.xml has no EdDSA signature"

gh release create "v$VERSION" -R "$RELEASES_REPO" --title "Axolotl $VERSION" --notes "Axolotl $VERSION" \
  "$ZIP" "$WORK/releases/appcast.xml"

rm -rf "$WORK"
echo "==> Released v$VERSION. Commit the version bump in project.yml."
