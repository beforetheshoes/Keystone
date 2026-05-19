#!/usr/bin/env bash
# Build Keystone in Release config and launch it. Debug builds skip a
# lot of SwiftUI compiler optimizations (view-tree inlining,
# `_ConditionalContent` collapsing, body-call deduplication) and run
# extra runtime checks (preconditions, bounds checks). That overhead
# alone can make a populated gallery feel like it's freezing on
# scroll, even when the code is fine.
#
# Always test perf in Release before chasing "freezes" in Debug code.

set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Building Keystone (Release, macOS)…"
xcodebuild \
  -project Keystone.xcodeproj \
  -scheme Keystone \
  -destination 'platform=macOS' \
  -configuration Release \
  build \
  >/dev/null

APP_DIR="$(xcodebuild \
  -project Keystone.xcodeproj \
  -scheme Keystone \
  -destination 'platform=macOS' \
  -configuration Release \
  -showBuildSettings 2>/dev/null \
  | awk -F ' = ' '/^[[:space:]]*BUILT_PRODUCTS_DIR/ {print $2; exit}')"

APP="${APP_DIR}/Keystone.app"

if [[ ! -d "$APP" ]]; then
  echo "ERROR: Release build didn't produce Keystone.app at $APP" >&2
  exit 1
fi

echo "==> Launching $APP"
open -n "$APP"
