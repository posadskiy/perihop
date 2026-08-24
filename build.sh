#!/usr/bin/env bash
# Builds PeriHop.app from the Swift package.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="PeriHop"
APP_DIR="${APP_NAME}.app"

# Built one arch at a time and lipo'd together — `swift build --arch a --arch b`
# needs the full Xcode build system (xcbuild), which isn't guaranteed to be
# present (e.g. Command Line Tools only, or some CI images). This works with
# just the Swift toolchain.
echo "==> Building (release, arm64)..."
swift build -c release --arch arm64
echo "==> Building (release, x86_64)..."
swift build -c release --arch x86_64

echo "==> Assembling ${APP_DIR}..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

lipo -create \
    ".build/arm64-apple-macosx/release/$APP_NAME" \
    ".build/x86_64-apple-macosx/release/$APP_NAME" \
    -output "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "Sources/$APP_NAME/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "Vendor/blueutil" "$APP_DIR/Contents/Resources/blueutil"
chmod +x "$APP_DIR/Contents/Resources/blueutil"
cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

echo "==> Signing (ad-hoc, binds Info.plist so macOS gives it a stable identity)..."
codesign --force --deep --sign - "$APP_DIR"

echo "==> Done: $APP_DIR"
echo "    Run with: open $APP_DIR"
