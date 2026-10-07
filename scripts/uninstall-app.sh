#!/bin/bash
set -euo pipefail
confirmed=false
delete_data=false
for arg in "$@"; do
  case "$arg" in
    --confirm) confirmed=true ;;
    --delete-data) delete_data=true ;;
    *) printf '%s\n' 'Usage: uninstall-app.sh --confirm [--delete-data]' >&2; exit 1 ;;
  esac
done
if [[ "$confirmed" != true ]]; then printf '%s\n' 'Review pending/uncertain jobs first; --confirm is required.' >&2; exit 1; fi
app_path=${MUNBYN_APP_PATH:-"$HOME/Applications/MUNBYN ITPP130B Bridge.app"}
bundle_id=${MUNBYN_BUNDLE_ID:-io.github.cmyker.munbyn-itpp130b-bridge}
actual_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")
if [[ "$actual_id" != "$bundle_id" || -L "$app_path" || "$app_path" != */'MUNBYN ITPP130B Bridge.app' ]]; then printf '%s\n' 'Refusing to remove a different/symlink application.' >&2; exit 1; fi
cli="$app_path/Contents/MacOS/munbyn-bridge"
"$cli" status >/dev/null
# Remove login first: authorization failure must not leave a removed queue and running app.
"$cli" login off
# Queue removal refuses pending bridge/native jobs. No file deletion proceeds on failure.
"$cli" uninstall-queue --confirm
"$cli" quit --confirm
for attempt in {1..30}; do
  if ! pgrep -x MunbynBridge >/dev/null; then break; fi
  sleep 0.1
done
if pgrep -x MunbynBridge >/dev/null; then printf '%s\n' 'Application still running; no files removed.' >&2; exit 1; fi
/bin/rm -rf -- "$app_path"
if [[ "$delete_data" == true ]]; then
  data_path="$HOME/Library/Application Support/MunbynBridge"
  if [[ -L "$data_path" ]]; then printf '%s\n' 'Refusing symlink data directory.' >&2; exit 1; fi
  /bin/rm -rf -- "$data_path"
fi
printf '%s\n' 'Bridge removed. Private data retained unless --delete-data was supplied. USB/default printers untouched.'
