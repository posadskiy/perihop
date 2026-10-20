#!/bin/bash
# Sign PeriHop.app with the hardened runtime so notarization accepts it.
#   scripts/sign-app.sh build/PeriHop.app "Developer ID Application: Name (TEAMID)"
set -euo pipefail

app="${1:?app path}"
identity="${2:?identity}"

if [[ ! -d "$app" ]]; then
  echo "No app at $app" >&2
  exit 1
fi

codesign --force --options runtime --timestamp --sign "$identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
