#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$PROJECT_DIR/dist/XPaste.app"
CONTENTS_DIR="$APP_DIR/Contents"

cd "$PROJECT_DIR"
swift build -c release

if [[ -d "$APP_DIR" ]]; then
    rm -rf "$APP_DIR"
fi

mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$PROJECT_DIR/.build/release/XPaste" "$CONTENTS_DIR/MacOS/XPaste"
cp "$PROJECT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"

if [[ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
fi

SIGNING_IDENTITY="${XPASTE_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning | awk '/"Apple Development:/ { print $2; exit }')"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "Error: no Apple Development signing identity found; refusing an unstable ad-hoc build." >&2
    exit 1
fi

codesign --force --deep --options runtime --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
DESIGNATED_REQUIREMENT="$(codesign -d -r- "$APP_DIR" 2>&1)"
if [[ "$DESIGNATED_REQUIREMENT" == *"cdhash"* ]]; then
    echo "Error: unstable cdhash-only designated requirement; refusing release build." >&2
    exit 1
fi
echo "$APP_DIR"
