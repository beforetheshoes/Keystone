#!/usr/bin/env bash
# Record an Instruments trace while you manually drive Keystone to
# reproduce a performance issue. Captures launch + steady-state +
# user-driven interactions.
#
# Usage:
#   bin/profile-gallery.sh                              # SwiftUI template, Debug, incremental
#   bin/profile-gallery.sh "Time Profiler"              # CPU hot frames
#   bin/profile-gallery.sh "Animation Hitches"          # scroll jank / hitches
#   bin/profile-gallery.sh --no-build                   # skip build, profile existing binary
#   bin/profile-gallery.sh --clean                      # force clean rebuild (slow — full SPM resolve)
#   bin/profile-gallery.sh --release                    # Release config (slower compile, no Debug overhead)
#   bin/profile-gallery.sh --clean --release "Time Profiler"   # ~5 min cold start, full diagnostic
#
# Defaults are Debug + incremental: routine iteration is fast because
# only changed files recompile. Use `--clean` only when you suspect
# incremental-build cache is lying, and `--release` only when Debug
# overhead is in question (per axiom-swiftui, Debug builds carry
# runtime invariant checks that can amplify perf issues).
#
# Templates: `xcrun xctrace list templates` for the full list. For
# main-thread hang diagnosis use "Animation Hitches" (catches >250ms
# blockers during scroll), "SwiftUI" (long view body updates lane),
# or "Time Profiler" (CPU sample stacks).
#
# Output:
#   .traces/gallery-<timestamp>.trace          # open in Instruments
#   .traces/gallery-<timestamp>.build.log      # full xcodebuild output
#   .traces/gallery-<timestamp>.summary.txt    # text-extracted hot frames
#
# Build discipline:
#   - Builds into `.derivedData/` (project-local) so the binary's path
#     is deterministic and can't be confused with Xcode-default
#     DerivedData. Both this script and any manual `xctrace`/Instruments
#     invocation should launch from `.derivedData/Build/Products/<config>/`.
#   - Build output is `tee`'d to terminal AND a log file — you can see
#     compile progress, AND failures are tailed loudly to stderr.
#   - Asserts the binary's mtime is newer than the script start. If
#     `xcodebuild` reports success but doesn't actually relink, the
#     script aborts loudly instead of silently profiling a stale build.
#   - When build is done, terminal-bells (\a) twice and prompts you to
#     press Enter before launching the recording — so you don't miss
#     the window after walking away from a slow build.

set -euo pipefail

cd "$(dirname "$0")/.."

# Parse args: optional flags, then optional template name.
CLEAN=0
NO_BUILD=0
CONFIG="Debug"
TEMPLATE="SwiftUI"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean) CLEAN=1; shift ;;
    --release) CONFIG="Release"; shift ;;
    --no-build) NO_BUILD=1; shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) echo "Unknown flag: $1" >&2; exit 1 ;;
    *)  TEMPLATE="$1"; shift ;;
  esac
done

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
TRACE_DIR=".traces"
TRACE_PATH="${TRACE_DIR}/gallery-${TIMESTAMP}.trace"
BUILD_LOG="${TRACE_DIR}/gallery-${TIMESTAMP}.build.log"
SUMMARY_PATH="${TRACE_DIR}/gallery-${TIMESTAMP}.summary.txt"
DERIVED_DATA=".derivedData"
APP_BINARY="${DERIVED_DATA}/Build/Products/Debug/Keystone.app/Contents/MacOS/Keystone"
# Release builds land at .../Products/Release/... not .../Debug/...
if [[ "$CONFIG" == "Release" ]]; then
  APP_BINARY="${DERIVED_DATA}/Build/Products/Release/Keystone.app/Contents/MacOS/Keystone"
fi

mkdir -p "$TRACE_DIR"

echo "==> Template:     $TEMPLATE"
echo "==> Configuration: $CONFIG"
echo "==> Trace output: $TRACE_PATH"
echo "==> Build log:    $BUILD_LOG"
echo "==> DerivedData:  $DERIVED_DATA"
[[ "$CLEAN" -eq 1 ]] && echo "==> Mode:         CLEAN BUILD"
echo

# Validate template up front — `xctrace record` only complains *after*
# the build, which wastes a minute.
if ! xcrun xctrace list templates 2>/dev/null | grep -Fx "$TEMPLATE" > /dev/null; then
    echo "ERROR: '$TEMPLATE' is not a known Instruments template." >&2
    echo "" >&2
    echo "Available templates:" >&2
    xcrun xctrace list templates 2>/dev/null | sed 's/^/  /' >&2
    echo "" >&2
    echo "Common choices for the gallery hang:" >&2
    echo "  bin/profile-gallery.sh 'Time Profiler'" >&2
    echo "  bin/profile-gallery.sh 'Animation Hitches'" >&2
    echo "  bin/profile-gallery.sh 'SwiftUI'" >&2
    exit 1
fi

if [[ "$NO_BUILD" -eq 1 ]]; then
  # Skip-build path: just verify the binary exists and proceed. No
  # mtime check (we're explicitly opting out of "fresh build" by
  # passing --no-build), but we do tell the user how stale the binary
  # they're about to profile actually is.
  if [[ ! -x "$APP_BINARY" ]]; then
    echo "ERROR: --no-build requested but no binary at $APP_BINARY" >&2
    echo "Run the script once without --no-build first to produce one." >&2
    exit 1
  fi
  BINARY_AGE_SECONDS=$(( $(date +%s) - $(stat -f %m "$APP_BINARY") ))
  echo "==> Skipping build (--no-build). Binary age: ${BINARY_AGE_SECONDS}s"
  echo "    Path: $APP_BINARY"
else
  # Stamp BEFORE the build so we can prove the binary's mtime advanced.
  # Using a sentinel file (touched to the exact second) instead of `date`
  # avoids clock-skew / fractional-second issues with `[[ -nt ]]`.
  BUILD_START_MARK="${TRACE_DIR}/.build-start.${TIMESTAMP}"
  touch "$BUILD_START_MARK"
  trap 'rm -f "$BUILD_START_MARK"' EXIT

  if [[ "$CLEAN" -eq 1 ]]; then
    echo "==> Removing $DERIVED_DATA (clean build requested — full SPM resolve + rebuild ahead)…"
    rm -rf "$DERIVED_DATA"
  fi

  echo "==> Building Keystone ($CONFIG, macOS) — output streamed below + saved to $BUILD_LOG"
  echo "    Filtering xcodebuild's verbose output to show only the actionable lines."
  echo "    Started at $(date '+%H:%M:%S')."
  BUILD_T0=$(date +%s)

  # Stream xcodebuild output through `tee` so the user sees it AND we
  # save the full log. Use `xcbeautify` if available for readable
  # output; otherwise fall back to a grep that surfaces the lines that
  # matter (CompileSwift module entries, errors, warnings). PIPESTATUS
  # captures xcodebuild's actual exit code through the pipeline.
  set +e
  if command -v xcbeautify > /dev/null 2>&1; then
    xcodebuild \
      -project Keystone.xcodeproj \
      -scheme Keystone \
      -destination 'platform=macOS' \
      -configuration "$CONFIG" \
      -derivedDataPath "$DERIVED_DATA" \
      build \
      2>&1 \
      | tee "$BUILD_LOG" \
      | xcbeautify
    BUILD_STATUS=${PIPESTATUS[0]}
  else
    xcodebuild \
      -project Keystone.xcodeproj \
      -scheme Keystone \
      -destination 'platform=macOS' \
      -configuration "$CONFIG" \
      -derivedDataPath "$DERIVED_DATA" \
      build \
      2>&1 \
      | tee "$BUILD_LOG" \
      | grep -E '^(CompileSwiftSources|CompileSwift |Linking|Resolved source packages|.+\.swift:[0-9]+:[0-9]+: (error|warning):|\*\* BUILD)' \
      || true
    BUILD_STATUS=${PIPESTATUS[0]}
  fi
  set -e

  BUILD_DT=$(( $(date +%s) - BUILD_T0 ))
  if [[ "$BUILD_STATUS" -ne 0 ]]; then
    echo "" >&2
    echo "ERROR: build failed after ${BUILD_DT}s. Last 40 lines of $BUILD_LOG:" >&2
    echo "----" >&2
    tail -40 "$BUILD_LOG" >&2
    echo "----" >&2
    echo "Full log: $BUILD_LOG" >&2
    exit 1
  fi
  echo "==> Build finished in ${BUILD_DT}s."

  # Step 2: verify the binary exists AND was (re)written by THIS build.
  # `xcodebuild ... build` can legitimately report success while skipping
  # the link step (incremental-build edge cases, stale dependency
  # tracking). Without this check, the script would happily profile a
  # binary from a previous run.
  if [[ ! -x "$APP_BINARY" ]]; then
    echo "ERROR: build succeeded but binary not found at:" >&2
    echo "  $APP_BINARY" >&2
    echo "Full log: $BUILD_LOG" >&2
    exit 1
  fi
  if [[ ! "$APP_BINARY" -nt "$BUILD_START_MARK" ]]; then
    echo "ERROR: build reported success but $APP_BINARY was not updated." >&2
    echo "  Binary mtime: $(date -r "$APP_BINARY" '+%Y-%m-%d %H:%M:%S')" >&2
    echo "  Build start:  $(date -r "$BUILD_START_MARK" '+%Y-%m-%d %H:%M:%S')" >&2
    echo "" >&2
    echo "This usually means incremental-build state lied. Retry with:" >&2
    echo "  $0 --clean ${TEMPLATE@Q}" >&2
    exit 1
  fi
  echo "==> Binary verified fresh ($(date -r "$APP_BINARY" '+%H:%M:%S')): $APP_BINARY"

  # Ring the terminal bell twice — this is the "build is done, come
  # back" signal. The user's complaint that motivated this change:
  # "several minutes before I ever see the application and by then I
  # usually get distracted." Audible ping reduces that miss rate.
  printf '\a'
  sleep 0.15
  printf '\a'
fi

# Step 3: record the trace. `--launch` starts a fresh process so we
# capture launch + steady-state. `--time-limit` bounds runtime so the
# script terminates even if the user forgets.
#
# IMPORTANT: do NOT hit Ctrl-C to stop the SwiftUI template — it sends
# SIGINT to xctrace, which fails to stop the ktrace session cleanly
# and the resulting trace contains schemas but no rows
# (`swiftui-causes`, `swiftui-update-groups`, `swiftui-updates` all
# end up empty). Let the time-limit fire instead, even if you finish
# reproducing earlier — wait it out. The Time Profiler template is
# more tolerant of Ctrl-C, but for consistency we let both run to
# completion.
echo
echo "==> Ready to record under xctrace ($TEMPLATE)."
echo "    You'll have 60s once recording starts. Drive the app: open Books,"
echo "    scroll to the freeze spot."
echo "    LET THE TIME-LIMIT FIRE — do NOT Ctrl-C, especially on the"
echo "    SwiftUI template (it wipes the recording's data on signal)."
echo
# Don't auto-launch — the build may have taken minutes, by which point
# the user has likely context-switched. Prompt for a key press so the
# recording window starts only when they're actually attending to it.
# Skipping the prompt when stdin isn't a TTY (CI, piped invocation).
if [[ -t 0 ]]; then
  read -r -n 1 -p "    Press any key to start the recording, or Ctrl-C to abort… " _
  echo
  echo
fi

# BUG FIX: xctrace's option parsing treats everything after `--` as
# arguments to the LAUNCHED process. The prior ordering
# (`--launch -- "$APP_BINARY" --time-limit 60s --output ...`) put
# `--time-limit` and `--output` into Keystone's argv instead of
# xctrace's, so xctrace had no time-limit and recordings only ever
# ended when the user pressed Ctrl-C. Inspect any prior trace's
# metadata — `<process arguments="--time-limit 60s --output …" />`
# confirms the flags landed on the wrong process. All xctrace options
# must come BEFORE `--launch`; nothing after `-- <APP_BINARY>` is for
# xctrace.
xctrace record \
  --template "$TEMPLATE" \
  --time-limit 60s \
  --output "$TRACE_PATH" \
  --launch -- "$APP_BINARY"

echo
echo "==> Trace saved: $TRACE_PATH"

# Step 4: extract a text summary so we don't need Instruments.app for
# a quick first look. The schema list depends on the template; the
# `time-profile` schema (CPU sampling) is present in SwiftUI / Time
# Profiler / Animation Hitches templates and gives the per-symbol hot
# list. `potential-hangs` lists main-thread blockers >250ms.
echo "==> Extracting text summary…"
{
  echo "# Trace:    $TRACE_PATH"
  echo "# Template: $TEMPLATE"
  echo "# Binary:   $APP_BINARY"
  echo "# Binary mtime: $(date -r "$APP_BINARY" '+%Y-%m-%d %H:%M:%S')"
  echo "# Recorded: $(date)"
  echo
  echo "## Available schemas"
  xcrun xctrace export --input "$TRACE_PATH" --toc 2>/dev/null || echo "(toc unavailable)"
  echo
  echo "## Potential hangs (>250ms on the main thread)"
  xcrun xctrace export \
    --input "$TRACE_PATH" \
    --xpath '/trace-toc/run[1]/data/table[@schema="potential-hangs"]' \
    2>/dev/null \
    || echo "(potential-hangs schema not present in this template)"
} > "$SUMMARY_PATH" 2>&1

echo "==> Summary saved: $SUMMARY_PATH"
echo
echo "Open the trace in Instruments:"
echo "  open '$TRACE_PATH'"
