#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MenuBarFold"
APP_DIR="build/${APP_NAME}.app"

swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp ".build/release/${APP_NAME}" "$APP_DIR/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

codesign --force --sign - "$APP_DIR" 2>/dev/null || true

echo "Built: $APP_DIR"
