#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
stage=$(mktemp -d "$PWD/build/.build.XXXXXX")
trap 'find "$stage" -depth -delete' EXIT
app="$stage/屏.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/Info.plist "$app/Contents/"
cp Resources/brightness_panel.html "$app/Contents/Resources/"
xcrun swift Tools/make-icon.swift "$stage/icon.png"
mkdir "$stage/Ping.iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$stage/icon.png" --out "$stage/Ping.iconset/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" "$stage/icon.png" \
        --out "$stage/Ping.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$stage/Ping.iconset" -o "$app/Contents/Resources/Ping.icns"
xcrun clang -arch arm64 -mmacosx-version-min=13.0 -O2 -Wall -Wextra -fobjc-arc \
    -framework Foundation -framework ApplicationServices -framework IOKit \
    Sources/displayctl.m -o "$app/Contents/MacOS/displayctl"
xcrun swiftc -target arm64-apple-macosx13.0 -swift-version 5 -O \
    Sources/*.swift -o "$app/Contents/MacOS/Ping"
codesign --force --sign - "$app/Contents/MacOS/displayctl"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
if [ -d "build/屏.app" ]; then
    mv "build/屏.app" "$stage/previous.app"
    if ! mv "$app" "build/屏.app"; then
        mv "$stage/previous.app" "build/屏.app"
        exit 1
    fi
else
    mv "$app" "build/屏.app"
fi
printf '%s\n' "$PWD/build/屏.app"
