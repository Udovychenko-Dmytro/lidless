#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Dmytro Udovychenko
# Installs the narrow one-time permission used by Enable, Disable, Low Power
# Mode changes and unattended shutdown.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_HELPER="$SCRIPT_DIR/lidless-poweroff"
# Written by ./build.sh next to the helper it describes, never hand-pinned: a
# typed-in digest would be a fourth hand-synchronised constant beside the three
# copies of the helper version, and those already drift with nothing checking.
SOURCE_MANIFEST="${LIDLESS_HELPER_MANIFEST:-$SCRIPT_DIR/lidless-manifest.sha256}"
INSTALL_DIR="/Library/PrivilegedHelperTools"
INSTALLED_HELPER="$INSTALL_DIR/io.github.lidless.poweroff"
SUDOERS_FILE="/etc/sudoers.d/lidless"
CURRENT_USER=""
RULE_CONTENT=""
ROOT_RULE_FILE=""
STAGED_HELPER=""

resolve_install_user() {
  local resolved_user

  if [ "$(id -u)" -eq 0 ]; then
    if [ -z "${SUDO_USER:-}" ] || [ "$SUDO_USER" = "root" ]; then
      echo "Run this installer as your login user, not from a root shell." >&2
      echo "Using 'sudo ./tools/install-auto-shutdown.sh' is supported only when sudo provides SUDO_USER." >&2
      return 2
    fi
    resolved_user="$SUDO_USER"
  else
    resolved_user="$(id -un)"
  fi

  case "$resolved_user" in
    ''|*[!A-Za-z0-9._-]*)
      echo "Unsupported login user name: $resolved_user" >&2
      return 2
      ;;
  esac
  printf '%s\n' "$resolved_user"
}

cleanup() {
  if [ -n "$ROOT_RULE_FILE" ]; then
    /usr/bin/sudo /bin/rm -f "$ROOT_RULE_FILE" || true
  fi
  if [ -n "$STAGED_HELPER" ]; then
    /bin/rm -f "$STAGED_HELPER" || true
  fi
}

# `sha256sum` and `md5sum` do not exist on macOS; shasum ships with the system
# Perl. Absolute path, like every other tool this installer runs.
helper_digest() {
  local out
  out="$(/usr/bin/shasum -a 256 "$1")" || return 1
  printf '%s\n' "${out%% *}"
}

# The manifest is shasum's own output format: "<64 hex>  <name>". Read with the
# shell rather than grep -E so this stays bash 3.2 plain.
manifest_digest_for() {
  local want="$1" digest name
  while read -r digest name; do
    if [ "$name" = "$want" ]; then
      printf '%s\n' "$digest"
      return 0
    fi
  done < "$SOURCE_MANIFEST"
  return 1
}

# Inside Lidless.app the scripts sit in Contents/Resources, one level under
# Contents/Info.plist. /Applications is drwxrwxr-x root:admin on a stock Mac, so
# that copy is writable without sudo — it is exactly the copy that must never be
# installed unverified.
running_from_app_bundle() {
  [ "$(/usr/bin/basename "$SCRIPT_DIR")" = "Resources" ] && [ -f "$SCRIPT_DIR/../Info.plist" ]
}

# Refuses the install unless the bytes about to be made root:wheel 0755 are the
# bytes ./build.sh recorded. Exit 3 is its own code: 1 already means "missing
# helper" and 2 "unusable install user", and the tests assert on both.
verify_source_helper() {
  local path="$1"
  local display="${2:-$1}"
  local expected actual

  if [ ! -f "$SOURCE_MANIFEST" ]; then
    if running_from_app_bundle; then
      echo "Missing integrity manifest: $SOURCE_MANIFEST" >&2
      echo "This copy of Lidless.app is incomplete or has been tampered with. Reinstall it before installing the permission." >&2
      return 3
    fi
    echo "No integrity manifest beside $display; skipping the digest check (source checkout)." >&2
    return 0
  fi

  if ! expected="$(manifest_digest_for lidless-poweroff)"; then
    echo "Refusing to install: $SOURCE_MANIFEST records no digest for lidless-poweroff." >&2
    return 3
  fi
  if ! actual="$(helper_digest "$path")"; then
    echo "Refusing to install: cannot digest $display." >&2
    return 3
  fi
  if [ "$expected" != "$actual" ]; then
    echo "Refusing to install: $display does not match the digest recorded in $SOURCE_MANIFEST." >&2
    echo "  expected $expected" >&2
    echo "  actual   $actual" >&2
    echo "This file would have been installed as root. Reinstall Lidless, or re-run ./build.sh if you edited the helper on purpose." >&2
    return 3
  fi
}

build_sudoers_rule() {
  local install_user="$1"
  printf '%s ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a lowpowermode 1, /usr/bin/pmset -c lowpowermode 0, /usr/bin/pmset -c lowpowermode 1, /usr/bin/pmset -b lowpowermode 0, /usr/bin/pmset -b lowpowermode 1, %s ""\n' \
    "$install_user" "$INSTALLED_HELPER"
}

main() {
  CURRENT_USER="$(resolve_install_user)" || return $?
  RULE_CONTENT="$(build_sudoers_rule "$CURRENT_USER")"
  trap cleanup EXIT

  if [ ! -f "$SOURCE_HELPER" ]; then
    echo "Missing helper: $SOURCE_HELPER" >&2
    return 1
  fi

  # Digest the copy that actually gets installed, not the source: digesting
  # $SOURCE_HELPER and then installing it would leave a TOCTOU window between
  # the two, in a directory the attacker is assumed to be able to write.
  STAGED_HELPER="$(/usr/bin/mktemp -t lidless-poweroff)"
  /bin/cat "$SOURCE_HELPER" > "$STAGED_HELPER"
  verify_source_helper "$STAGED_HELPER" "$SOURCE_HELPER" || return $?

  printf '%s\n' "$RULE_CONTENT" | /usr/sbin/visudo -cf -

  echo "Lidless will install:"
  echo "  helper: $INSTALLED_HELPER (root:wheel, mode 0755)"
  echo "  sudoers: $SUDOERS_FILE (root:wheel, mode 0440)"
  echo
  echo "The exact sudoers rule is:"
  printf '  %s\n' "$RULE_CONTENT"
  echo
  /usr/bin/sudo /usr/bin/install -d -o root -g wheel -m 0755 "$INSTALL_DIR"
  /usr/bin/sudo /usr/bin/install -o root -g wheel -m 0755 "$STAGED_HELPER" "$INSTALLED_HELPER"
  /usr/bin/sudo /usr/bin/install -d -o root -g wheel -m 0755 /etc/sudoers.d
  ROOT_RULE_FILE="$(/usr/bin/sudo /usr/bin/mktemp /etc/sudoers.d/lidless.XXXXXX)"
  printf '%s\n' "$RULE_CONTENT" | /usr/bin/sudo /usr/bin/tee "$ROOT_RULE_FILE" >/dev/null
  /usr/bin/sudo /bin/chmod 0440 "$ROOT_RULE_FILE"
  /usr/bin/sudo /usr/sbin/visudo -cf "$ROOT_RULE_FILE"
  /usr/bin/sudo /bin/mv -f "$ROOT_RULE_FILE" "$SUDOERS_FILE"
  ROOT_RULE_FILE=""
  /usr/bin/sudo /usr/sbin/visudo -c

  echo "Lidless power permission installed."
  echo "Enable, Disable, Low Power Mode and automatic shutdown are now password-free."
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
