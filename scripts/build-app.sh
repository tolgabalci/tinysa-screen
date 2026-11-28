#!/bin/bash
# Builds tinySA Screen.app in build/: a release build for Apple silicon and Intel Macs, signed ad hoc, or with the
# identity in SIGN_IDENTITY ("Developer ID Application: …", with the hardened runtime and a timestamp, as notarizing
# needs; scripts/release.sh does that and the rest).
#   scripts/build-app.sh            the app
#   scripts/build-app.sh --zip      the app, and build/tinySA-Screen-<version>.zip for a release
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
APP="build/tinySA Screen.app"

# The link is given the SDK as -isysroot. SwiftPM's build engine runs the compiler without xcrun's SDKROOT and hands
# clang only --sysroot, so the app said it was built with the deployment target's SDK (13.0), and macOS 26 and later
# showed it in their old look: no Liquid Glass, a toolbar of gray, cramped buttons that stayed gray in front.
SDK=$(xcrun --sdk macosx --show-sdk-path)
SWIFT_BUILD=(swift build -c release --arch arm64 --arch x86_64
  -Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$SDK")
"${SWIFT_BUILD[@]}"
BINARY=$("${SWIFT_BUILD[@]}" --show-bin-path)/tinysa-screen
SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)
for arch in $(lipo -archs "$BINARY"); do
  BUILT_WITH=$(vtool -arch "$arch" -show-build "$BINARY" | awk '$1 == "sdk" { print $2 }')
  [[ "$BUILT_WITH" == "$SDK_VERSION" ]] || {
    echo "The $arch app says it was built with the macOS $BUILT_WITH SDK, not $SDK_VERSION" >&2
    exit 1
  }
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/tinysa-screen"
sed -e "s/@VERSION@/$VERSION/" -e "s/@BUILD@/$BUILD/" Resources/Info.plist >"$APP/Contents/Info.plist"

ICONS=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONS"
for px in 16 32 128 256 512; do
  sips -z $px $px Resources/AppIcon.png --out "$ICONS/icon_${px}x${px}.png" >/dev/null
  sips -z $((px * 2)) $((px * 2)) Resources/AppIcon.png --out "$ICONS/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$ICONS" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONS")"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "Built $APP ($VERSION, build $BUILD): $(lipo -archs "$APP/Contents/MacOS/tinysa-screen")"

if [[ "${1:-}" == "--zip" ]]; then
  ZIP="build/tinySA-Screen-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Zipped $ZIP"
fi
