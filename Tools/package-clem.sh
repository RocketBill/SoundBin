#!/bin/zsh
# Wrap an already signed, notarized SoundBin.app for CLEM without modifying the app or Sparkle feed.
# Usage: Tools/package-clem.sh /path/to/SoundBin.app /path/to/SoundBin_CLEM.zip
set -euo pipefail
cd "${0:A:h}/.."

[[ $# == 2 ]] || { print -u2 "Usage: $0 SoundBin.app SoundBin_CLEM.zip"; exit 1; }
app=${1:A}
archive=${2:A}
[[ -d $app && $archive == *.zip ]] || { print -u2 "Expected an app bundle and ZIP output path."; exit 1; }
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
[[ $bundle_id == uk.co.barnes-ward.SoundBin ]] || { print -u2 "This is not the SoundBin app bundle."; exit 1; }
codesign --verify --deep --strict "$app"

stage=$(mktemp -d "${TMPDIR:-/tmp}/soundbin-clem.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/payload" "$stage/screenshots" "${archive:h}"
ditto "$app" "$stage/payload/SoundBin.app"
cp Docs/icon.png "$stage/icon.png"
cp Docs/screenshot-dark.png "$stage/screenshots/dark.png"
cp Docs/screenshot-light.png "$stage/screenshots/light.png"
python3 - "$stage/clem.json" "$version" <<'PY'
import json, sys
manifest = {
    "manifestVersion": 1,
    "id": "uk.co.barnes-ward.SoundBin",
    "name": "SoundBin",
    "developer": "Billy Ward",
    "description": "A fast, native sound browser for macOS 26 or later. Browse waveforms, preview sounds, organise favourites and collections, and drag audio into your editor. SoundBin handles its own updates.",
    "category": "apps",
    "version": sys.argv[2],
    "icon": "icon.png",
    "screenshots": [
        {"path": "screenshots/dark.png", "caption": "SoundBin’s waveform browser in dark mode."},
        {"path": "screenshots/light.png", "caption": "SoundBin’s waveform browser in light mode."},
    ],
    "artifact": {
        "kind": "desktop-app",
        "path": "payload/SoundBin.app",
        "bundleId": "uk.co.barnes-ward.SoundBin",
        "bundleName": "SoundBin.app",
        "installPath": "/Applications/SoundBin.app",
        "openPath": "/Applications/SoundBin.app",
    },
}
with open(sys.argv[1], "w") as output:
    json.dump(manifest, output, indent=2, ensure_ascii=False)
    output.write("\n")
PY
codesign --verify --deep --strict "$stage/payload/SoundBin.app"
ditto -c -k "$stage" "$archive"
print "Packaged SoundBin $version for CLEM: $archive"
