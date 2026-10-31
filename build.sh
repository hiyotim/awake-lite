#!/bin/bash
# Собирает AwakeLite.app без Xcode: нужен только swiftc из Command Line Tools.
set -euo pipefail

cd "$(dirname "$0")"

app="AwakeLite.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

swiftc -O -parse-as-library \
    -target "$(uname -m)-apple-macos13.0" \
    Sources/*.swift \
    -o "$app/Contents/MacOS/AwakeLite"

cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app" >/dev/null

echo "Готово: $PWD/$app"
