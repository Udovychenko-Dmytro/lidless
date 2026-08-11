#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Dmytro Udovychenko
#
# Builds build/Lidless.app from source. Requires Xcode command line tools.
#
# Everything this script produces lives under one directory, so the repo root
# stays as it is in git. Override it with OUT=... if you want the bundle
# somewhere else:
#
#   OUT=dist ./build.sh
#
set -euo pipefail

cd "$(dirname "$0")"

OUT="${OUT:-build}"
BIN="Lidless"
# Recovery tool for Panel blackout, shipped inside the bundle. Its name is also
# hardcoded in Sources/main.swift (rescueBinaryName) and lidless.sh
# (rescue_display) — three places, so grep for it before renaming.
RESCUE_BIN="lidless-display-rescue"
APP="$OUT/$BIN.app"
WORK="$OUT/.lidless-intermediates"  # object files, logs, per-arch slices
# Built here, not at $APP directly, so a failure anywhere below leaves the
# previous good $APP untouched — the old script deleted $APP and created an
# empty one at that exact path before compilation even started, so any
# failure (a slice, codesign) left a partial/broken bundle at the advertised
# product path and destroyed the last known-good build in the process. See
# docs/ARCHITECTURE.md — review round 3 (flagged in
# rounds 2 and 3; fixed here). $STAGING and $APP are both under $OUT, so the
# final `mv` itself is a fast rename, not a copy — but it's still preceded by
# a separate `rm -rf -- "$APP"`, so the two together are not one atomic swap
# (a crash between them would leave nothing at $APP). See docs/ARCHITECTURE.md
# for why that gap is an accepted scope boundary here rather than a fix.
STAGING="$WORK/$BIN.app"
MIN_MACOS="13.0"

# OUT may point at an existing directory containing unrelated files. Remove
# only paths owned by this build instead of recursively deleting all of OUT —
# and NOT $APP itself; that is only ever replaced at the very end, on full
# success.
case "$OUT" in
  ""|"/"|"."|".."|-*)
    echo "Unsafe OUT value: $OUT" >&2
    exit 2
    ;;
esac
rm -rf -- "$WORK"
mkdir -p -- "$WORK" "$STAGING/Contents/MacOS" "$STAGING/Contents/Resources"

echo "Generating icon..."
# The icon is optional, so every step of it is guarded. The compile used to be a
# bare command under `set -e`, which killed the whole build on a broken
# generate-icon.swift — the exact opposite of what the message below promises.
# Its stderr goes to the same log as iconutil's, so a failure in either lands
# where the message points. ICON_LOG is copied out of $WORK because $WORK is
# deleted on success, and the old message named a path that no longer existed by
# the time anyone read it.
ICON_LOG="$OUT/lidless-icon.log"
if swiftc -O -o "$WORK/generate-icon" Sources/generate-icon.swift 2>"$WORK/icon.log" && \
   "$WORK/generate-icon" "$WORK/AppIcon.iconset" >/dev/null 2>>"$WORK/icon.log" && \
   iconutil -c icns "$WORK/AppIcon.iconset" -o "$STAGING/Contents/Resources/AppIcon.icns" 2>>"$WORK/icon.log"; then
  echo "  icon ok"
  rm -f -- "$ICON_LOG"
else
  cp "$WORK/icon.log" "$ICON_LOG" 2>/dev/null || true
  echo "  icon skipped (see $ICON_LOG) — the app still builds, just without one"
fi

echo "Compiling..."

# Build each slice separately, then merge, so the result runs on both
# Apple Silicon and Intel.
#
# Sources/SMCSensors.swift is in the app list only, and must stay out of the
# $RESCUE_BIN list below: it talks to AppleSMC through an IOConnect call that
# has no timeout and cannot be killed, and the rescue tool's whole job is to
# work when the app is the thing that died. See that file's header.
ARCHES=(arm64 x86_64)

slices=()
for arch in "${ARCHES[@]}"; do
  if swiftc -parse-as-library -O \
      -target "${arch}-apple-macos${MIN_MACOS}" \
      -o "$WORK/${BIN}-${arch}" \
      Sources/main.swift Sources/SystemProbe.swift Sources/VirtualDisplay.swift \
      Sources/PanelLog.swift Sources/SMCSensors.swift \
      2>"$WORK/${BIN}-${arch}.log"; then
    slices+=("$WORK/${BIN}-${arch}")
    echo "  ${arch} ok"
  else
    echo "  ${arch} skipped (see $WORK/${BIN}-${arch}.log)"
  fi
done

# A universal build is part of the artifact contract. Silently publishing one
# architecture would make a locally successful build fail on another Mac.
# Intermediates stay in place on failure because their logs explain which
# slice failed and why — and $APP (if a previous build exists) is untouched.
if [ ${#slices[@]} -ne ${#ARCHES[@]} ]; then
  echo "Build failed: all of ${ARCHES[*]} are required. Logs:"
  cat "$WORK/${BIN}"-*.log
  echo "$APP was left untouched."
  exit 1
fi

lipo -create -output "$STAGING/Contents/MacOS/$BIN" "${slices[@]}"

# The way out of Panel blackout. Built as its own binary rather than a mode of the
# app because it has to work when the app is the thing that died, and it lands in
# Contents/MacOS rather than beside the scripts in Contents/Resources: those are
# shell scripts, and a Mach-O executable under Resources breaks bundle sealing.
echo "Compiling $RESCUE_BIN..."
rescue_slices=()
for arch in "${ARCHES[@]}"; do
  if swiftc -parse-as-library -O \
      -target "${arch}-apple-macos${MIN_MACOS}" \
      -o "$WORK/${RESCUE_BIN}-${arch}" \
      Sources/DisplayRescue.swift Sources/VirtualDisplay.swift Sources/SystemProbe.swift \
      2>"$WORK/${RESCUE_BIN}-${arch}.log"; then
    rescue_slices+=("$WORK/${RESCUE_BIN}-${arch}")
    echo "  ${arch} ok"
  else
    echo "  ${arch} skipped (see $WORK/${RESCUE_BIN}-${arch}.log)"
  fi
done

# Not optional. Shipping the app without its recovery tool would leave the one
# failure mode this feature can produce — a screen nobody can see — with no
# supported way back.
if [ ${#rescue_slices[@]} -ne ${#ARCHES[@]} ]; then
  echo "Build failed: all of ${ARCHES[*]} are required for $RESCUE_BIN. Logs:"
  cat "$WORK/${RESCUE_BIN}"-*.log
  echo "$APP was left untouched."
  exit 1
fi

lipo -create -output "$STAGING/Contents/MacOS/$RESCUE_BIN" "${rescue_slices[@]}"

cp Info.plist "$STAGING/Contents/Info.plist"
cp LICENSE "$STAGING/Contents/Resources/LICENSE.txt"
cp TRADEMARKS.md "$STAGING/Contents/Resources/TRADEMARKS.md"
cp tools/lidless-poweroff "$STAGING/Contents/Resources/lidless-poweroff"
cp tools/install-auto-shutdown.sh "$STAGING/Contents/Resources/install-auto-shutdown.sh"
cp tools/uninstall-auto-shutdown.sh "$STAGING/Contents/Resources/uninstall-auto-shutdown.sh"
chmod +x "$STAGING/Contents/Resources/lidless-poweroff" \
         "$STAGING/Contents/Resources/install-auto-shutdown.sh" \
         "$STAGING/Contents/Resources/uninstall-auto-shutdown.sh"
chmod +x "$STAGING/Contents/MacOS/$BIN" "$STAGING/Contents/MacOS/$RESCUE_BIN"

# Integrity manifest for install-auto-shutdown.sh, generated here so no digest
# is ever typed by hand. It is written before the codesign below on purpose, so
# the bundle seal covers it. /Applications is group-writable, so a local process
# can overwrite the shipped helper; the installer refuses to make a file root
# unless it still matches this line.
(
  cd "$STAGING/Contents/Resources"
  /usr/bin/shasum -a 256 lidless-poweroff > lidless-manifest.sha256
)

# Ad-hoc signature: enough for the app to run locally. Distributing it to other
# people would need a Developer ID and notarization instead.
#
# Nested code is signed explicitly, innermost first, and the bundle WITHOUT
# --deep. `--deep` is documented as deprecated for signing as of macOS 13.0 —
# this script's own MIN_MACOS — and it applies the outer options recursively to
# nested content, which is almost never what anyone wants. It was harmless while
# the only nested items were shell scripts; $RESCUE_BIN is a real Mach-O and
# makes it live.
codesign --force --sign - "$STAGING/Contents/MacOS/$RESCUE_BIN"
codesign --force --sign - "$STAGING"

ARCHS=$(lipo -archs "$STAGING/Contents/MacOS/$BIN" 2>/dev/null || echo unknown)

# Only now touch the advertised product path, and only after everything above
# has fully succeeded — mv, not copy (both paths are under $OUT, so this is a
# fast rename). Not a single atomic swap, though: the rm below and this mv are
# two separate commands, so there's a brief window where $APP doesn't exist.
rm -rf -- "$APP"
mv -- "$STAGING" "$APP"
rm -rf -- "$WORK"

echo
echo "Built $APP  ($ARCHS)"
echo "Run it with: open $APP"
echo "It opens a window, and adds a menu bar item — which a full menu bar on a"
echo "notched Mac can park behind the notch, out of sight. The window is the way in."
