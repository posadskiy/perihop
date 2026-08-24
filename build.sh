#!/usr/bin/env bash
# Builds PeriHop.app from the Swift package.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="PeriHop"
BUILD_DIR=".build/release"
APP_DIR="${APP_NAME}.app"

echo "==> Building (release)..."
swift build -c release

echo "==> Assembling ${APP_DIR}..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "Sources/$APP_NAME/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "Vendor/blueutil" "$APP_DIR/Contents/Resources/blueutil"
chmod +x "$APP_DIR/Contents/Resources/blueutil"
cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

echo "==> Signing (ad-hoc, binds Info.plist so macOS gives it a stable identity)..."
codesign --force --deep --sign - "$APP_DIR"

echo "==> Done: $APP_DIR"
echo "    Run with: open $APP_DIR"
