#!/bin/bash
# Собирает AwakeLite.app без Xcode: нужен только swiftc из Command Line Tools.
set -euo pipefail

cd "$(dirname "$0")"

app="AwakeLite.app"
helper="$app/Contents/MacOS/AwakeLiteHelper"
target="$(uname -m)-apple-macos13.0"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Integrations"

# Menu-bar app. App-only sources are compiled here, never into the helper.
swiftc -O -parse-as-library \
    -target "$target" \
    Sources/*.swift Sources/Core/*.swift Sources/Integrations/*.swift Sources/Adapters/*.swift \
    -o "$app/Contents/MacOS/AwakeLite"

# Short-lived hook helper: library code only (core, integrations, adapters,
# normalizer) plus its own entry point. No app-only source is included.
swiftc -O \
    -target "$target" \
    Sources/Core/*.swift Sources/Integrations/*.swift Sources/Adapters/*.swift \
    Sources/HookNormalizer.swift Helper/main.swift \
    -o "$helper"

cp Resources/Info.plist "$app/Contents/Info.plist"
# Bundled, trusted integration manifests and inert templates stay with the app.
cp -R Resources/Integrations/. "$app/Contents/Resources/Integrations/"
# App icon referenced by CFBundleIconFile.
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

# Nested code is signed before the bundle that seals it.
codesign --force --sign - "$helper" >/dev/null
codesign --force --sign - "$app" >/dev/null

echo "Готово: $PWD/$app"
