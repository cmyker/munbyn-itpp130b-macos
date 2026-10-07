#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bundle_id=${MUNBYN_BUNDLE_ID:-io.github.cmyker.munbyn-itpp130b-bridge}
if [[ ! "$bundle_id" =~ ^[A-Za-z0-9]+([.-][A-Za-z0-9-]+)+$ ]]; then printf '%s\n' 'Invalid bundle identifier' >&2; exit 1; fi
swift build -c release --arch arm64
bin_dir=$(swift build -c release --arch arm64 --show-bin-path)
app_path="$PWD/dist/MUNBYN ITPP130B Bridge.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$bin_dir/MunbynBridge" "$app_path/Contents/MacOS/"
cp "$bin_dir/munbyn-bridge" "$app_path/Contents/MacOS/"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$app_path/Contents/Info.plist"
cp Resources/ITPP130B.ppd "$app_path/Contents/Resources/"
cp LICENSE "$app_path/Contents/Resources/Original-Code-LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$app_path/Contents/Resources/"
cp docs/third-party/* "$app_path/Contents/Resources/"
# Explicit project configuration only. Existing signing certificates are never selected implicitly.
signing_identity=${MUNBYN_SIGNING_IDENTITY:--}
codesign --force --sign "$signing_identity" "$app_path/Contents/MacOS/munbyn-bridge"
codesign --force --sign "$signing_identity" "$app_path"
codesign --verify --strict "$app_path"
for executable in MunbynBridge munbyn-bridge; do
  otool -L "$app_path/Contents/MacOS/$executable"
  if otool -L "$app_path/Contents/MacOS/$executable" | tail -n +2 | /usr/bin/grep -E '/opt/homebrew|/usr/local|/Users/'; then printf '%s\n' 'Unexpected developer dependency' >&2; exit 1; fi
done
printf '%s\n' "$app_path"
