#!/usr/bin/env bash
# Build a Developer ID signed, notarized PeriHop.dmg for the website.
#   ./build.sh
#
# The app lands in build/PeriHop.app and the disk image in build/PeriHop.dmg.
# Apple Silicon only. The macOS 27 SDK deprecates x86_64 for this deployment target.
#
# The certificate is the only Developer ID Application identity in the login keychain, or
# DEVELOPER_ID_APP="Developer ID Application: Your Name (TEAMID)".
# The same certificate that signs GrammarBar signs this app. Nothing new is created
# on the Apple Developer site.
#
# Notarize with the same stored notarytool profile GrammarBar uses:
#   export NOTARY_KEYCHAIN_PROFILE="grammarbar-notary"
# or an App Store Connect API key:
#   export NOTARY_KEY_PATH="$HOME/.private_keys/AuthKey_XXXXXXXXXX.p8"
#   export NOTARY_KEY_ID="XXXXXXXXXX"
#   export NOTARY_ISSUER_ID="00000000-0000-0000-0000-000000000000"
#
# Store a notary profile once, with an app-specific password from appleid.apple.com:
#   xcrun notarytool store-credentials "grammarbar-notary" \
#     --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-password"
#
# Signing and notarization ask Apple for a timestamp, so this needs the network.
set -euo pipefail
cd "$(dirname "$0")"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Run this on a Mac. It needs swift, hdiutil, codesign, and notarytool." >&2
  exit 1
fi

# shellcheck source=scripts/developer-id.sh
source scripts/developer-id.sh
identity="$(resolve_developer_id)"

profile="${NOTARY_KEYCHAIN_PROFILE:-}"
key_path="${NOTARY_KEY_PATH:-}"
key_id="${NOTARY_KEY_ID:-}"
issuer_id="${NOTARY_ISSUER_ID:-}"
notarize=()
if [[ -n "$profile" ]]; then
  notarize=(--keychain-profile "$profile")
elif [[ -n "$key_path$key_id$issuer_id" ]]; then
  if [[ -z "$key_path" || -z "$key_id" || -z "$issuer_id" ]]; then
    echo "Set all of NOTARY_KEY_PATH, NOTARY_KEY_ID, and NOTARY_ISSUER_ID." >&2
    exit 1
  fi
  if [[ ! -f "$key_path" ]]; then
    echo "No App Store Connect key at $key_path" >&2
    exit 1
  fi
  notarize=(--key "$key_path" --key-id "$key_id" --issuer "$issuer_id")
else
  echo "Set NOTARY_KEYCHAIN_PROFILE, or NOTARY_KEY_PATH, NOTARY_KEY_ID, and NOTARY_ISSUER_ID." >&2
  echo "The GrammarBar profile is NOTARY_KEYCHAIN_PROFILE=grammarbar-notary." >&2
  echo "Customers' Macs block a disk image Apple has not notarized." >&2
  exit 1
fi

if [[ -z "${PERIHOP_SKIP_TEST:-}" ]]; then
  swift test
fi

echo "==> Building (release, arm64)..."
swift build -c release --arch arm64
bin="$(swift build -c release --arch arm64 --show-bin-path)"

app="build/PeriHop.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/PeriHop" "$app/Contents/MacOS/PeriHop"
cp "Sources/PeriHop/Info.plist" "$app/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "THIRD_PARTY_LICENSES.md" "$app/Contents/Resources/THIRD_PARTY_LICENSES.md"

if ! lipo -archs "$app/Contents/MacOS/PeriHop" | grep -qx "arm64"; then
  echo "$app is not an arm64 build: $(lipo -archs "$app/Contents/MacOS/PeriHop")" >&2
  exit 1
fi

echo "==> Signing with $identity..."
bash scripts/sign-app.sh "$app" "$identity"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Staple the ticket onto the app before it goes inside the disk image.
notarize_zip="$work/PeriHop-notarize.zip"
ditto -c -k --keepParent "$app" "$notarize_zip"
echo "==> Notarizing the app..."
xcrun notarytool submit "$notarize_zip" "${notarize[@]}" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"

stage="$work/dmg"
mkdir -p "$stage"
ditto "$app" "$stage/PeriHop.app"
ln -s /Applications "$stage/Applications"

dmg="build/PeriHop.dmg"
echo "==> Creating $dmg..."
hdiutil create -volname "PeriHop" -srcfolder "$stage" -ov -format UDZO "$dmg"
# Gatekeeper checks the disk image signature. The signed app inside is not enough.
codesign --force --timestamp --sign "$identity" "$dmg"
codesign --verify --verbose=2 "$dmg"

echo "==> Notarizing the disk image..."
xcrun notarytool submit "$dmg" "${notarize[@]}" --wait
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg"

echo "Wrote $dmg ($(shasum -a 256 "$dmg" | cut -d' ' -f1))"
echo "Signed app: $app"
echo "Install over the existing copy:"
echo "  osascript -e 'quit app \"PeriHop\"' || true"
echo "  ditto \"$PWD/$app\" /Applications/PeriHop.app"
