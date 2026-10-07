#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /tmp/munbyn-synthetic.XXXXXX)
trap 'rm -rf "$work"' EXIT
swift build
bin_dir=$(swift build --show-bin-path)
swift scripts/make-fixtures.swift "$work"
/usr/bin/cupstestppd -q Resources/ITPP130B.ppd
/usr/sbin/cupsfilter -p Resources/ITPP130B.ppd -m application/vnd.cups-raster -o PageSize=Label100x150 "$work/100x150.pdf" > "$work/portrait.raster"
result=$("$bin_dir/munbyn-bridge" raster-info "$work/portrait.raster")
printf '%s\n' "$result"
[[ "$result" == *'Validated 2 labels'* && "$result" == *'799x1199'* ]]
/usr/sbin/cupsfilter -p Resources/ITPP130B.ppd -m application/vnd.cups-raster -n 2 -o Collate=True -o orientation-requested=4 -o PageSize=Label4x6 "$work/4x6.pdf" > "$work/copies.raster"
result=$("$bin_dir/munbyn-bridge" raster-info "$work/copies.raster")
printf '%s\n' "$result"
[[ "$result" == *'Validated 4 labels'* && "$result" == *'812x1218'* ]]
# A landscape-sized document needs the converter's explicit fit/rotation policy.
# orientation-requested alone in cupsfilter does not reproduce CUPS queue preprocessing.
/usr/sbin/cupsfilter -p Resources/ITPP130B.ppd -m application/vnd.cups-raster -o fit-to-page=true -o PageSize=Label100x150 "$work/100x150-landscape.pdf" > "$work/landscape.raster"
result=$("$bin_dir/munbyn-bridge" raster-info "$work/landscape.raster")
printf '%s\n' "$result"
[[ "$result" == *'Validated 2 labels'* && "$result" == *'799x1199'* ]]
printf '%s\n' 'Apple raster conversion validated; no queue installed, no Bluetooth, no physical printing.'
