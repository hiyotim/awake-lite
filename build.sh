#!/bin/bash
# Собирает AwakeLite.app без Xcode: нужен только swiftc из Command Line Tools.
set -euo pipefail

cd "$(dirname "$0")"

app="AwakeLite.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Integrations"

swiftc -O -parse-as-library \
    -target "$(uname -m)-apple-macos13.0" \
    Sources/*.swift Sources/Core/*.swift Sources/Integrations/*.swift \
    -o "$app/Contents/MacOS/AwakeLite"

cp Resources/Info.plist "$app/Contents/Info.plist"
# Bundled, trusted integration manifests and inert templates stay with the app.
cp -R Resources/Integrations/. "$app/Contents/Resources/Integrations/"
codesign --force --sign - "$app" >/dev/null

echo "Готово: $PWD/$app"
