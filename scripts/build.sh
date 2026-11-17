#!/bin/sh
# One-command build: ./scripts/build.sh [--debug] → build/LectureLift.app (+ build/LectureLift.dmg)
# Signing: $LECTURELIFT_SIGN_IDENTITY, else the first "Apple Development" identity in the keychain, else ad-hoc
# (ad-hoc: macOS re-asks for the audio-capture permission after every rebuild).
set -eu
cd "$(dirname "$0")/.."
CONF=release; [ "${1:-}" = "--debug" ] && CONF=debug
VERSION=$(git describe --tags --always 2>/dev/null || echo 0.1.0-dev)
swift build -c "$CONF" --product LectureLift
swift build -c "$CONF" --product lecturelift-render
BIN=$(swift build -c "$CONF" --show-bin-path)
APP="build/LectureLift.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/LectureLift" "$APP/Contents/MacOS/LectureLift"
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
# SwiftUI resolves Text("…") in Bundle.main: copy the compiled string tables (de/en) to the app's
# own Resources, otherwise only the source language (de) would ever be shown.
for l in "$BIN"/LectureLift_HSApp.bundle/Contents/Resources/*.lproj "$BIN"/LectureLift_HSApp.bundle/*.lproj; do [ -d "$l" ] && cp -R "$l" "$APP/Contents/Resources/"; done
# older SwiftPM (Xcode 16) does not compile the catalog: generate the tables ourselves
ls -d "$APP"/Contents/Resources/en.lproj > /dev/null 2>&1 || python3 -I scripts/xcstrings_to_strings.py Sources/HSApp/Resources/Localizable.xcstrings "$APP/Contents/Resources"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
[ -f THIRD_PARTY_NOTICES_RUST.md ] && cp THIRD_PARTY_NOTICES_RUST.md "$APP/Contents/Resources/"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$(date +%Y%m%d%H%M)/" packaging/Info.plist > "$APP/Contents/Info.plist"
if [ -f vendor/libdf/lib/libdf.dylib ] && [ -f vendor/libdf/models/DeepFilterNet3_onnx.tar.gz ]; then
  mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/Resources/Models"
  cp vendor/libdf/lib/libdf.dylib "$APP/Contents/Frameworks/"
  cp vendor/libdf/models/DeepFilterNet3_onnx.tar.gz "$APP/Contents/Resources/Models/"
else
  echo "note: libDF not built (scripts/build_libdf.sh) — Qualität mode will be unavailable" >&2
fi
mkdir -p build && cp "$BIN/lecturelift-render" build/
ID="${LECTURELIFT_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/{print $2; exit}')}"
if [ -z "$ID" ]; then
  echo "WARNING: no signing identity found, signing ad-hoc (permission will be re-requested after each build)" >&2
  ID="-"
fi
codesign --force --sign "$ID" --timestamp=none build/lecturelift-render
codesign --force --deep --sign "$ID" --timestamp=none --identifier io.github.aetsr.lecturelift "$APP"
codesign --verify --strict "$APP"
echo "built $APP ($CONF, $VERSION), signed with ${ID%%${ID#????????}}…"
if [ "${LECTURELIFT_NO_DMG:-0}" != 1 ]; then
  rm -f build/LectureLift.dmg
  STAGE=$(mktemp -d); cp -R "$APP" "$STAGE/"; cp LICENSE THIRD_PARTY_NOTICES.md README.md "$STAGE/"
  [ -f THIRD_PARTY_NOTICES_RUST.md ] && cp THIRD_PARTY_NOTICES_RUST.md "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -quiet -volname "LectureLift" -srcfolder "$STAGE" -ov -format UDZO build/LectureLift.dmg
  rm -rf "$STAGE"
  echo "built build/LectureLift.dmg"
fi
