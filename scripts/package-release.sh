#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Always package a fresh native build, never a pre-existing developer bundle.
scripts/build-app.sh
app_name='MUNBYN ITPP130B Bridge.app'
app_path="$PWD/dist/$app_name"
plist="$app_path/Contents/Info.plist"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
channel=$(/usr/libexec/PlistBuddy -c 'Print :MunbynReleaseChannel' "$plist")
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$channel" =~ ^[A-Za-z0-9]+([.-][A-Za-z0-9]+)*$ ]]; then
  printf '%s\n' 'Invalid bundle release version/channel.' >&2; exit 1
fi
release_version="$version-$channel"
for executable in MunbynBridge munbyn-bridge; do
  if [[ "$(/usr/bin/lipo -archs "$app_path/Contents/MacOS/$executable")" != arm64 ]]; then
    printf '%s\n' 'Only validated Apple Silicon packages are supported.' >&2; exit 1
  fi
done
source_revision=$(git rev-parse HEAD)
if ! git diff --quiet || ! git diff --cached --quiet; then source_revision="$source_revision (uncommitted changes)"; fi
signature=$(/usr/bin/codesign -dv "$app_path" 2>&1)
signing='configured signature; inspect codesign for identity'
if [[ "$signature" == *'Signature=adhoc'* ]]; then signing='ad-hoc (no Developer ID)'; fi

work=$(mktemp -d /tmp/munbyn-release.XXXXXX)
mount_path="$work/mounted"
mounted=false
cleanup() {
  if [[ "$mounted" == true ]]; then /usr/bin/hdiutil detach "$mount_path" >/dev/null 2>&1 || true; fi
  /bin/rm -rf -- "$work"
}
trap cleanup EXIT
mkdir -p "$work/image" "$work/extracted" "$mount_path"
/usr/bin/ditto --norsrc --noextattr --noqtn --noacl "$app_path" "$work/image/$app_name"
ln -s /Applications "$work/image/Applications"
cp docs/INSTALL.txt "$work/image/READ-ME-FIRST.txt"
cat > "$work/image/BUILD-INFO.txt" <<EOF
Application: MUNBYN ITPP130B Bridge
Release: $release_version
Architecture: arm64 (Apple Silicon)
Source revision: $source_revision
Source: https://github.com/cmyker/munbyn-itpp130b-macos
Signing: $signing
Notarization: not performed by this packaging tool
Deployment target: macOS 13; tested runtime: macOS 15.7.9
Status: experimental alpha; see validation evidence in the source repository
EOF
stem="MUNBYN-ITPP130B-Bridge-$release_version-macos-arm64"
zip_name="$stem.zip"
dmg_name="$stem.dmg"
/usr/bin/ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl "$work/image/$app_name" "$work/$zip_name"
/usr/bin/ditto -x -k "$work/$zip_name" "$work/extracted"
/usr/bin/codesign --verify --strict "$work/extracted/$app_name"
/usr/bin/diff -qr "$app_path" "$work/extracted/$app_name"

/usr/bin/hdiutil create -quiet -volname 'MUNBYN ITPP130B Bridge' -srcfolder "$work/image" -format UDZO "$work/$dmg_name"
/usr/bin/hdiutil verify -quiet "$work/$dmg_name"
/usr/bin/hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$mount_path" "$work/$dmg_name"
mounted=true
/usr/bin/codesign --verify --strict "$mount_path/$app_name"
/usr/bin/diff -qr "$app_path" "$mount_path/$app_name"
[[ "$(readlink "$mount_path/Applications")" == /Applications ]]
/usr/bin/cmp docs/INSTALL.txt "$mount_path/READ-ME-FIRST.txt"
/usr/bin/hdiutil detach -quiet "$mount_path"
mounted=false

(cd "$work" && /usr/bin/shasum -a 256 "$dmg_name" "$zip_name" > SHA256SUMS)
output="$PWD/dist/releases"
mkdir -p "$output"
mv -f "$work/$dmg_name" "$work/$zip_name" "$work/SHA256SUMS" "$output/"
printf '%s\n' "Verified DMG and ZIP; no app launched, queue changed or Bluetooth accessed." "$output/$dmg_name" "$output/$zip_name" "$output/SHA256SUMS"
