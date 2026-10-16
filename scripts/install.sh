#!/bin/bash
# Builds tinySA Screen and puts it in ~/Applications (Spotlight finds it there).
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/tinySA Screen.app"
cp -R "build/tinySA Screen.app" "$HOME/Applications/"
echo "Installed $HOME/Applications/tinySA Screen.app"
