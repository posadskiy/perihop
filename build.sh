#!/usr/bin/env bash
# Builds PeriHop.app from the Swift package.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="PeriHop"
APP_DIR="${APP_NAME}.app"

# arm64 only. The macOS 27 SDK deprecates x86_64 for this deployment target.
echo "==> Building (release, arm64)..."
swift build -c release --arch arm64

echo "==> Assembling ${APP_DIR}..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp ".build/arm64-apple-macosx/release/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "Sources/$APP_NAME/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "THIRD_PARTY_LICENSES.md" "$APP_DIR/Contents/Resources/THIRD_PARTY_LICENSES.md"

echo "==> Signing (ad-hoc, binds Info.plist so macOS gives it a stable identity)..."
codesign --force --deep --sign - "$APP_DIR"

echo "==> Done: $APP_DIR"
echo "    Run with: open $APP_DIR"
