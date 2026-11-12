#!/usr/bin/env bash
# Build build/PeriHop.app for running on this Mac. Signed with the Developer
# ID so macOS keeps the Bluetooth permission, but not notarized, so it is not
# for handing to another Mac. Use ./build.sh for that.
#   scripts/dev-app.sh          release build
#   scripts/dev-app.sh debug    debug build, with the perihop://snapshot hook
set -euo pipefail
config="${1:-release}"
cd "$(dirname "$0")/.."

# shellcheck source=scripts/developer-id.sh
source scripts/developer-id.sh
identity="$(resolve_developer_id)"

swift build -c "$config" --arch arm64
bin="$(swift build -c "$config" --arch arm64 --show-bin-path)"

app="build/PeriHop.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/PeriHop" "$app/Contents/MacOS/PeriHop"
cp "Sources/PeriHop/Info.plist" "$app/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "THIRD_PARTY_LICENSES.md" "$app/Contents/Resources/THIRD_PARTY_LICENSES.md"
codesign --force --options runtime --sign "$identity" "$app"
echo "Built $app"
