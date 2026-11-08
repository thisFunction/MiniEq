#!/bin/bash
# Builds MiniEQ.app with Apple's command-line tools (no Xcode project needed).
#
#   ./build.sh           build ./build/MiniEQ.app for this Mac
#   ./build.sh install   build, copy into /Applications (or ~/Applications), and launch it
#   ./build.sh dmg       build for Apple Silicon + Intel and make dist/MiniEQ-<version>.dmg to share
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p logs
exec > >(tee logs/build.log) 2>&1   # keep a copy of this run's output in logs/build.log

MODE="${1:-build}"
case "$MODE" in
  build|install|dmg) ;;
  *) echo "Usage: ./build.sh [install|dmg]"; exit 1 ;;
esac

APP_NAME="MiniEQ"
BUNDLE_ID="com.skoczylas.MiniEQ"
MIN_MACOS="14.4"
APP="build/$APP_NAME.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "❌ Apple's command-line developer tools aren't installed."
  echo "   Run:  xcode-select --install    then run this script again."
  exit 1
fi

OS_VERSION="$(sw_vers -productVersion)"
IFS=. read -r OS_MAJOR OS_MINOR _ <<< "$OS_VERSION"
OS_MINOR="${OS_MINOR:-0}"
if (( OS_MAJOR < 14 || (OS_MAJOR == 14 && OS_MINOR < 4) )); then
  echo "❌ MiniEQ needs macOS $MIN_MACOS or newer (this Mac has $OS_VERSION)."
  exit 1
fi

# A DMG for other people includes both Apple Silicon and Intel code.
if [ "$MODE" = "dmg" ]; then ARCHS="arm64 x86_64"; else ARCHS="$(uname -m)"; fi

SDK="$(xcrun --sdk macosx --show-sdk-path)"
echo "▶ Building $APP_NAME $VERSION on macOS $OS_VERSION"
echo "  $(xcrun swiftc --version 2>&1 | head -n 1)"

rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

SLICES=()
for ARCH in $ARCHS; do
  echo "▶ Compiling for $ARCH"
  xcrun swiftc \
    -O -swift-version 5 -parse-as-library \
    -sdk "$SDK" -target "$ARCH-apple-macos$MIN_MACOS" \
    -framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox \
    Sources/*.swift \
    -o "build/obj/$APP_NAME-$ARCH"
  SLICES+=("build/obj/$APP_NAME-$ARCH")
done
lipo -create -output "$APP/Contents/MacOS/$APP_NAME" "${SLICES[@]}"

cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ "$MODE" != "dmg" ]; then
  # Your own builds also write a plain-text status log into this project's logs folder.
  plutil -insert MiniEQLogFile -string "$PWD/logs/MiniEQ.log" "$APP/Contents/Info.plist"
fi
if [ -d Resources/AppIcon.iconset ]; then
  iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc signature with a fixed identity, so macOS remembers the audio permission across rebuilds.
if ! codesign --force --sign - --identifier "$BUNDLE_ID" \
     --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP" 2>/dev/null; then
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi
echo "✅ Built $APP ($(lipo -archs "$APP/Contents/MacOS/$APP_NAME"))"

case "$MODE" in
  install)
    DEST="/Applications"
    [ -w "$DEST" ] || DEST="$HOME/Applications"
    mkdir -p "$DEST"
    if pgrep -x "$APP_NAME" >/dev/null; then
      echo "▶ Quitting the running $APP_NAME"
      pkill -TERM -x "$APP_NAME" || true
      for _ in $(seq 1 50); do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.1; done
    fi
    rm -rf "$DEST/$APP_NAME.app"
    ditto "$APP" "$DEST/$APP_NAME.app"
    open "$DEST/$APP_NAME.app"
    echo "✅ Installed $DEST/$APP_NAME.app and launched it — look for the knob icon in the menu bar."
    ;;
  dmg)
    STAGE="build/dmg"
    DMG="dist/$APP_NAME-$VERSION.dmg"
    rm -rf "$STAGE"
    mkdir -p "$STAGE" dist
    ditto "$APP" "$STAGE/$APP_NAME.app"
    ln -s /Applications "$STAGE/Applications"          # so people can drag the app straight in
    cp "Resources/Read Me First.txt" "$STAGE/"
    rm -f "$DMG"
    hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
    rm -rf "$STAGE"
    echo "✅ Created $DMG ($(du -h "$DMG" | cut -f1 | xargs)) — for Macs on macOS $MIN_MACOS or newer."
    open -R "$DMG"                                       # show it in Finder
    ;;
  build)
    echo "   Run it with:  open $APP     (or use: ./build.sh install)"
    ;;
esac
