#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Dmytro Udovychenko

set -euo pipefail

cd "$(dirname "$0")/.."

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <semver>" >&2
  exit 2
fi

VERSION="$1"
if ! [[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid Semantic Version: $VERSION" >&2
  exit 2
fi

TAG="v$VERSION"
APP="build/Lidless.app"
ARCHIVE="Lidless-$VERSION-macos-universal.zip"
CHECKSUM="$ARCHIVE.sha256"
EXPECTED_REMOTE="https://github.com/Udovychenko-Dmytro/lidless.git"

if [ -n "$(git status --porcelain)" ]; then
  echo "Refusing to package a dirty checkout." >&2
  exit 3
fi

if [ "$(git describe --tags --exact-match HEAD 2>/dev/null || true)" != "$TAG" ]; then
  echo "HEAD must be the exact tag $TAG." >&2
  exit 3
fi

if [ "$(git remote get-url origin)" != "$EXPECTED_REMOTE" ]; then
  echo "This release must be packaged from the public GitHub checkout." >&2
  exit 3
fi

git ls-files --error-unmatch "$APP/Contents/Info.plist" >/dev/null
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [ "$PLIST_VERSION" != "$VERSION" ]; then
  echo "Bundle version $PLIST_VERSION does not match requested version $VERSION." >&2
  exit 3
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lidless-release.XXXXXX")"
trap 'rm -rf -- "$TMP_DIR"' EXIT

/usr/bin/ditto "$APP" "$TMP_DIR/Lidless.app"
/usr/bin/xattr -cr "$TMP_DIR/Lidless.app"

codesign --verify --deep --strict --verbose=2 "$TMP_DIR/Lidless.app"
for executable_path in \
  "$TMP_DIR/Lidless.app/Contents/MacOS/Lidless" \
  "$TMP_DIR/Lidless.app/Contents/MacOS/lidless-display-rescue"; do
  ARCHITECTURES="$(lipo -archs "$executable_path")"
  case " $ARCHITECTURES " in
    *" arm64 "*) ;;
    *) echo "Missing arm64 in $executable_path: $ARCHITECTURES" >&2; exit 3 ;;
  esac
  case " $ARCHITECTURES " in
    *" x86_64 "*) ;;
    *) echo "Missing x86_64 in $executable_path: $ARCHITECTURES" >&2; exit 3 ;;
  esac
done

mkdir -p dist
rm -f -- "dist/$ARCHIVE" "dist/$CHECKSUM"
(
  cd "$TMP_DIR"
  /usr/bin/ditto -c -k --keepParent Lidless.app "$OLDPWD/dist/$ARCHIVE"
)
(
  cd dist
  /usr/bin/shasum -a 256 "$ARCHIVE" > "$CHECKSUM"
)

VERIFY_DIR="$TMP_DIR/verify"
mkdir -p "$VERIFY_DIR"
/usr/bin/ditto -x -k "dist/$ARCHIVE" "$VERIFY_DIR"
codesign --verify --deep --strict --verbose=2 "$VERIFY_DIR/Lidless.app"
cmp LICENSE "$VERIFY_DIR/Lidless.app/Contents/Resources/LICENSE.txt"
cmp TRADEMARKS.md "$VERIFY_DIR/Lidless.app/Contents/Resources/TRADEMARKS.md"

echo "Created dist/$ARCHIVE"
echo "Created dist/$CHECKSUM"
