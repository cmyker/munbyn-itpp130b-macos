#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
dev_dir=$(xcode-select -p)
frameworks="$dev_dir/Library/Developer/Frameworks"
# Swift Testing otherwise runs tests concurrently. Keep CPU-heavy raster checks
# from consuming the short wall-clock deadlines in transport failure tests.
# Async operations and concurrency exercised within each test remain enabled.
if [[ -d "$frameworks/Testing.framework" ]]; then
  swift test --no-parallel -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays -Xswiftc -F -Xswiftc "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" "$@"
else
  swift test --no-parallel "$@"
fi
