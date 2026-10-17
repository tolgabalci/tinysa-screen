#!/bin/bash
# Publishes a release of tinySA Screen that opens without a security prompt: built, signed with a Developer ID,
# notarized by Apple and stapled, zipped, put on the GitHub release v<VERSION> (made by the Release workflow when the tag
# was pushed, or here), and the Homebrew cask brought up to date (tolgabalci/homebrew-tap).
#
#   scripts/release.sh
#
# Needs, on this Mac:
#   - a "Developer ID Application" certificate in the keychain (Xcode › Settings › Accounts › Manage Certificates);
#   - an App Store Connect API key for notarizing: NOTARY_KEY_ID, NOTARY_ISSUER_ID and NOTARY_KEY (the .p8 file) in the
#     environment, or in ~/.config/tinysa-screen/notary.env;
#   - gh, logged in, for the release and the tap.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
TAG="v$VERSION"
ZIP="build/tinySA-Screen-$VERSION.zip"
APP="build/tinySA Screen.app"
CONFIG="$HOME/.config/tinysa-screen/notary.env"
[[ -f "$CONFIG" ]] && source "$CONFIG"

IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
[[ -n "$IDENTITY" ]] || { echo "No Developer ID Application certificate in the keychain" >&2; exit 1; }
: "${NOTARY_KEY_ID:?set NOTARY_KEY_ID (App Store Connect API key)}" "${NOTARY_ISSUER_ID:?set NOTARY_ISSUER_ID}"
: "${NOTARY_KEY:?set NOTARY_KEY to the path of the .p8 file}"
git diff --quiet HEAD -- || { echo "Commit first: the release is built from what is committed" >&2; exit 1; }

echo "Building $VERSION, signed by $IDENTITY"
SIGN_IDENTITY="$IDENTITY" scripts/build-app.sh
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Notarizing (a few minutes)"
xcrun notarytool submit "$ZIP" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"   # again, with the ticket stapled in

echo "Publishing $ZIP"
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$ZIP" --clobber
else
  awk -v v="## $VERSION" 'index($0, v) == 1 {on=1; next} /^## / {on=0} on' CHANGELOG.md > build/notes.md
  gh release create "$TAG" "$ZIP" --title "tinySA Screen $VERSION" --notes-file build/notes.md
fi

echo "Updating the Homebrew cask"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
TAP=$(mktemp -d)/homebrew-tap
if ! gh repo view tolgabalci/homebrew-tap >/dev/null 2>&1; then
  # The first release: the tap, from packaging/homebrew.
  mkdir -p "$TAP/Casks"
  cp packaging/homebrew/README.md "$TAP/README.md"
  cp packaging/homebrew/tinysa-screen.rb "$TAP/Casks/tinysa-screen.rb"
  git -C "$TAP" init -q -b main
  git -C "$TAP" add README.md Casks/tinysa-screen.rb
  git -C "$TAP" commit -q -m "tinysa-screen"
  gh repo create tolgabalci/homebrew-tap --public --description "Homebrew casks: tinySA Screen" --source "$TAP" --push
fi
rm -rf "$TAP"
gh repo clone tolgabalci/homebrew-tap "$TAP" -- --quiet
sed -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" \
  "$TAP/Casks/tinysa-screen.rb" > "$TAP/Casks/tinysa-screen.rb.new"
mv "$TAP/Casks/tinysa-screen.rb.new" "$TAP/Casks/tinysa-screen.rb"
git -C "$TAP" add Casks/tinysa-screen.rb
git -C "$TAP" commit -q -m "tinysa-screen $VERSION"
git -C "$TAP" push -q
echo "Released $VERSION: brew install --cask tolgabalci/tap/tinysa-screen"
