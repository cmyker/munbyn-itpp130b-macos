#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_app="$PWD/dist/MUNBYN ITPP130B Bridge.app"
target_dir=${1:-"$HOME/Applications"}
if [[ ! -d "$source_app" ]]; then printf '%s\n' 'Run scripts/build-app.sh first.' >&2; exit 1; fi
mkdir -p "$target_dir"
target_app="$target_dir/MUNBYN ITPP130B Bridge.app"
if [[ -e "$target_app" ]]; then
  existing_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target_app/Contents/Info.plist")
  desired_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")
  if [[ "$existing_id" != "$desired_id" ]]; then printf '%s\n' 'Existing application has a different bundle ID; refusing overwrite.' >&2; exit 1; fi
  if pgrep -x MunbynBridge >/dev/null; then printf '%s\n' 'Quit the bridge before updating its application bundle.' >&2; exit 1; fi
fi
/usr/bin/ditto "$source_app" "$target_app"
codesign --verify --strict "$target_app"
printf '%s\n' "$target_app"
