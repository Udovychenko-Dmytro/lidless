#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Dmytro Udovychenko
#
# lidless — keep a MacBook reachable over remote desktop with the lid closed.
#
# Run from a terminal: sudo and sysadminctl ask for the password themselves.
# This script never reads, stores or forwards your password.
#
set -euo pipefail

PID_FILE="$HOME/.lidless_caffeinate_pid"
SCREENLOCK_FILE="$HOME/.lidless_screenlock_prev"
LOWPOWER_FILE="$HOME/.lidless_lowpower_prev"

# Interprocess lock so a concurrent CLI + app `on`/`off` cannot race on stale
# state and start two caffeinate processes. Not removed by `off` — unlike the
# other state files above, a lock file's whole point is to persist as an inert
# marker between operations; see with_lock() and docs/ARCHITECTURE.md
# Phase 4.
LOCK_FILE="$HOME/.lidless_lock"

# Unix epoch seconds, written when Lidless is turned on. The app writes the
# same file, so the "shut down after N hours" watchdog works no matter which of the
# two enabled it — including after the app has been quit.
ENABLEDAT_FILE="$HOME/.lidless_enabled_at"
SHUTDOWN_PENDING_FILE="$HOME/.lidless_shutdown_pending"
SHUTDOWN_CANCEL_FILE="$HOME/.lidless_shutdown_cancel"
# Written by the app only — the script never blacks a panel out. Read by status()
# so an SSH session can find out that the screen is dark, which is exactly when
# SSH is the only way in.
DISPLAY_MARKER_FILE="$HOME/.lidless_display_prev"
DISPLAY_HEARTBEAT_FILE="$HOME/.lidless_display_heartbeat"
# Matches DisplayRescue.heartbeatStaleAfter / SystemProbe.panelHeartbeatStaleAfter.
DISPLAY_HEARTBEAT_STALE_AFTER=25

# Installed root-owned helper for the one destructive unattended action. It
# accepts no arguments, requests shutdown before best-effort lid cleanup.
# Keep this path in sync with SystemProbe.automaticShutdownHelperPath.
AUTOMATIC_SHUTDOWN_HELPER="/Library/PrivilegedHelperTools/io.github.lidless.poweroff"
AUTOMATIC_SHUTDOWN_HELPER_VERSION="2"
: "${AUTOMATIC_SHUTDOWN_HELPER_VERSION_CHECK_PATH:=$AUTOMATIC_SHUTDOWN_HELPER}"

# The app (Lidless.app) keeps its checkboxes here. The script reads the same
# domain, so ticking a box in the app changes what `lidless.sh on` does.
DEFAULTS_DOMAIN="io.github.lidless"

# This tool used to be called "remote mode" and kept its state in ~/.remote_mode_*.
# A session that was already running at the time of the rename would otherwise be
# stranded: the new code would see a clean slate, `off` would not know there was
# anything to restore, and the saved Low Power Mode value would be lost — while
# the Mac carried on ignoring the lid. Adopt the old files once, then forget they
# existed.
#
# Safe to delete this function, and its call below, once no machine can still be
# carrying the old names.
# The suffixes are spelled out rather than derived from the variables above:
# bash 3.2 pattern substitution on a path full of slashes is easy to get subtly
# wrong, and this runs on every invocation. Keep the list in step with the four
# *_FILE definitions above.
migrate_legacy_state() {
  local suffix
  for suffix in caffeinate_pid screenlock_prev lowpower_prev enabled_at; do
    if [ ! -e "$HOME/.lidless_$suffix" ] && [ -f "$HOME/.remote_mode_$suffix" ]; then
      mv "$HOME/.remote_mode_$suffix" "$HOME/.lidless_$suffix" 2>/dev/null || true
    fi
  done
}
migrate_legacy_state

# ---------------------------------------------------------------------------
# Fallbacks
#
# Used when the defaults domain has no answer — which is the normal case for
# anyone who only ever uses the script. Edit these freely; the app's setting
# wins whenever the app has one.
# ---------------------------------------------------------------------------

# Run the machine cooler (and quieter, on Macs that have fans) while Lidless
# is on. The previous per-source setting is restored by `off`.
ENABLE_LOW_POWER_MODE=0

# Optional: also relax the screen lock grace period while Lidless is on.
# Off by default — it needs your account password on every toggle (sysadminctl
# has no other way) and weakens physical security. Set to 1 to enable.
# Restoring on `off` always happens if a saved value exists, regardless of this.
ENABLE_SCREENLOCK_TOGGLE=0
LIDLESS_SCREENLOCK_DELAY=3600

# caffeinate -si rather than -s, so the assertion also holds on battery.
ENABLE_KEEP_AWAKE_ON_BATTERY=1

# Whether `off` also stops caffeinate processes this tool did not start.
ENABLE_STOP_ALL_CAFFEINATE=0

# Watchdog limits, both off by default. tools/lidless-check.sh enforces
# these; see the README.
SHUTDOWN_AFTER_HOURS_DEFAULT=0
SHUTDOWN_BELOW_BATTERY_PERCENT_DEFAULT=0

# How far in the future a stored "enabled at" timestamp is allowed to sit
# before it is treated as corrupted rather than ordinary clock skew. Matches
# Sources/main.swift's enabledAtFutureTolerance so both implementations repair
# a bad timestamp the same way instead of disagreeing about what "future" means.
ENABLED_AT_FUTURE_TOLERANCE=300

# Cadence for confirming that a caffeinate process either started or exited,
# instead of trusting process-launch/kill status alone (docs/ARCHITECTURE.md's own
# rule: confirm by re-reading, never by $?). Matches Sources/main.swift's
# caffeinateExitPollNanoseconds/caffeinateExitPollAttempts (50ms x 20 =~ 1s).
# Overridable so tests do not have to spend a real second per assertion.
: "${CAFFEINATE_EXIT_POLL_ATTEMPTS:=20}"
: "${CAFFEINATE_EXIT_POLL_SECONDS:=0.05}"
: "${AUTOMATIC_SHUTDOWN_GRACE_SECONDS:=60}"

# Effective settings, filled in by load_settings(). Declared here so the file can
# be sourced under `set -u` without calling it.
SET_LOW_POWER=0
SET_SCREENLOCK=0
SET_SCREENLOCK_DELAY=3600
SET_KEEP_AWAKE_ON_BATTERY=1
SET_STOP_ALL_CAFFEINATE=0
SET_SHUTDOWN_AFTER_HOURS=0
SET_SHUTDOWN_BELOW_BATTERY_PERCENT=0
# App-only, and printed by status() for that reason alone: the script cannot arm
# or undo Panel blackout (see off()), but README promises status shows what every
# shared setting resolves to, and both of these live in the same defaults domain
# as the six above. Reported, never acted on.
SET_BLACKOUT_BUILTIN_DISPLAY=0
SET_PANEL_MODE="virtual"
SETTINGS_SOURCE="fallbacks"
AUTOMATIC_SHUTDOWN_WARNING=""

usage() {
  cat <<EOF
Usage: $(basename "$0") {on|off|status|set|cancel-shutdown|rescue-display}

  on     keep the Mac awake and make it ignore lid close
  off    restore normal sleep and lid behaviour
  status show what is currently active
  set    list the shared settings, or 'set <key> <value>' to change one.
         Values are validated against the app's own choices, so a value
         its Pickers cannot display is refused rather than written.
  cancel-shutdown
         cancel a watchdog shutdown during its 60-second grace period
  rescue-display
         put the built-in screen back after Panel blackout. Only ever
         makes displays visible, so it is safe to run at any time.
         Add --explain to print what it would do without touching
         anything. Panel blackout itself belongs to the app: a shell
         command cannot hold the virtual display open (see off()).

Run from a terminal: sudo asks for the password itself.
EOF
  exit 1
}

# ---------------------------------------------------------------------------
# Parsers
#
# These read command output on stdin and print a result. They run no commands
# of their own, which is what makes them testable: tests/run.sh feeds them
# fixture files captured from real Macs instead of the live system.
#
# None of them exit early. `awk ... exit` in the middle of a pipeline kills the
# producer with SIGPIPE, which under `set -o pipefail` turns a successful parse
# into a failed one — the same trap described at is_caffeinated() below.
# ---------------------------------------------------------------------------

# stdin: `pmset -g`. Prints: ignored | normal | unknown
#
# Real `pmset -g` only ever prints the SleepDisabled line when it is 1 — a
# normal Mac (SleepDisabled=0) omits the key entirely. This is NOT inferred
# from tests/fixtures/pmset-g-sleepdisabled-off.txt (that fixture is
# synthetic, per tests/fixtures/README.md — an earlier version of this
# comment wrongly called it a real capture) — it is confirmed by Apple's own
# open-source pmset.c, show_system_power_settings(): it only prints the
# SleepDisabled line when `CFDictionaryGetValue(system_power_settings,
# kIOPMSleepDisabledKey)` is non-null, i.e. only when the key has actually
# been set at least once. So a missing key is the ordinary case and must read
# "normal", not "unknown" — but a line that *did* match (the key was seen)
# with no usable value (truncated, corrupted, anything but exactly "1" or
# "0") is genuinely ambiguous and must not be folded into the same "normal"
# as a key that was never there at all. This parser has no way to tell
# "pmset failed outright" from "well-formed output with the key legitimately
# absent" from content alone — that distinction is lid_state()'s job (exit
# status + empty
# check), not this pure parser's. See docs/ARCHITECTURE.md.
parse_sleep_disabled() {
  # $1 == "SleepDisabled", not /SleepDisabled/ — a substring regex would also
  # match an unrelated key like "NotSleepDisabled" or "xSleepDisabledx" (review
  #  round 2). NF == 2 required too — a stray extra token
  # ("SleepDisabled garbage 1") must not fall through to whatever $2 happens
  # to be; Swift's equivalent requires exactly two fields for the same
  # reason, so both sides agree on a malformed line (review round 3).
  # More than one matching row is ambiguous, not "last one wins" — this used
  # to silently keep overwriting `value` on each match while Swift's
  # equivalent returned on its first match, so a duplicated/contradictory row
  # disagreed between the two languages instead of both calling it unknown.
  # review round 4.
  awk '
    $1 == "SleepDisabled" { seen++; value = (NF == 2 ? $2 : "") }
    END {
      if (seen == 0) print "normal"
      else if (seen > 1) print "unknown"
      else if (value == "1") print "ignored"
      else if (value == "0") print "normal"
      else print "unknown"
    }
  '
}

# stdin: `pmset -g custom`. Prints one key from one section.
#
# Desktops (Mac mini, iMac, Mac Studio) have no "Battery Power" section at all,
# and section order is not guaranteed, so match on the headers themselves rather
# than assuming a fixed range. Prints an empty line when the section is absent.
parse_pmset_custom() {
  local section="$1" key="$2"
  # NF == 2 required, same as every other tri-state reader in this file — a
  # stray extra token ("lowpowermode 1 garbage") used to fall through to
  # whatever $2 happened to be here, while Swift's equivalent (which does
  # require exactly two fields) rejected it as unreadable. review
  # round 5.
  awk -v want="$section" -v key="$key" '
    /Power:[[:space:]]*$/                { insec = (index($0, want) > 0); next }
    insec && $1 == key && seen == 0 {
      seen = 1
      if (NF == 2) val = $2
    }
    END                                  { print val }
  '
}

# stdin: `pmset -g custom`. Prints one section's Low Power Mode value, under
# whichever of its two names this macOS uses: 26 prints `lowpowermode`, 15 and
# earlier print `powermode` for the exact same setting that `pmset -a
# lowpowermode 1` writes. Reading only the first name made every Low Power Mode
# reading on macOS 15 "unknown". Mirrors Swift's SystemProbe.lowPowerKeys.
#
# The FIRST row carrying either name decides, malformed included (one pass, one
# `seen` flag over both names) — not "try one name, then the other". A
# malformed row means the output cannot be trusted; falling back would turn it
# into a confirmed reading from a different line, and Swift would disagree.
# `powermode 2` (High Power Mode) is left to the callers' 0|1 case, i.e. read
# as unknown: the restore only writes lowpowermode 0/1, so treating it as a
# confirmed "off" would demote a high-power Mac to normal on off().
parse_lowpower_field() {
  local section="$1"
  awk -v want="$section" '
    /Power:[[:space:]]*$/ { insec = (index($0, want) > 0); next }
    insec && ($1 == "lowpowermode" || $1 == "powermode") && seen == 0 {
      seen = 1
      if (NF == 2) val = $2
    }
    END { print val }
  '
}

# stdin: `sysadminctl -screenLock status` output. That command writes to stderr,
# so callers must redirect it with 2>&1.
# Prints: off | immediate | <seconds> | unknown
parse_screenlock() {
  local out lower
  out=$(cat)
  lower=$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')
  if [ -z "$out" ]; then
    echo "unknown"
  elif [[ "$lower" == *"is off"* ]]; then
    echo "off"
  elif [[ "$lower" == *immediate* ]]; then
    echo "immediate"
  elif [[ "$out" =~ ([0-9]+)[[:space:]]+seconds ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "unknown"
  fi
}

# stdin: `pmset -g ps`. Prints the battery percentage, or nothing on a machine
# with no battery.
parse_battery_percent() {
  local out
  out=$(cat)
  if [[ "$out" =~ ([0-9]+)% ]]; then
    echo "${BASH_REMATCH[1]}"
  fi
}

# ---------------------------------------------------------------------------
# Settings
#
# Shared with the app through its defaults domain, so the two cannot disagree
# about what "on" means. Anything the app has not set falls back to the
# constants above, which is what keeps the script standalone.
# ---------------------------------------------------------------------------

# `defaults` normalises booleans to 1/0, but a hand-written domain may hold
# true/YES, so accept those spellings too.
truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

# Prints one key from the app's domain, or nothing when the domain or key is
# absent. `defaults read` exits 1 and writes to stderr in both those cases.
read_default_raw() {
  defaults read "$DEFAULTS_DOMAIN" "$1" 2>/dev/null || true
}

# read_default <key> <fallback>
read_default() {
  local value
  value=$(read_default_raw "$1")
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$2"
  fi
}

yes_no() {
  if truthy "${1:-}"; then echo "yes"; else echo "no"; fi
}

# Mirrors SystemProbe.panelMode(in:) in Sources/main.swift's terms: leading and
# trailing whitespace is tolerated, "dim" and "virtual" round-trip, and anything
# else — including absent, empty, or a typo — resolves to the default rather than
# refusing. status() must report the value the APP would act on, not the raw
# string, or the two would disagree about the same Mac exactly the way the
# settings block above exists to prevent.
panel_mode_value() {
  local raw
  raw=$(printf '%s' "${1:-}" | tr -d '[:space:]')
  case "$raw" in
    dim) echo "dim" ;;
    *) echo "virtual" ;;
  esac
}

# A limit of 0 means the guard is disabled.
never_or() {
  if [ "${1:-0}" = "0" ] || [ -z "${1:-}" ]; then echo "never"; else echo "${1}${2:-}"; fi
}

# The app's "Never" is 0; sysadminctl spells the same thing "off".
screenlock_target() {
  if [ "${1:-}" = "0" ]; then echo "off"; else echo "${1:-}"; fi
}

load_settings() {
  local app_setting_values

  SET_LOW_POWER=$(read_default lowPowerWhileActive "$ENABLE_LOW_POWER_MODE")
  SET_SCREENLOCK=$(read_default relaxScreenLock "$ENABLE_SCREENLOCK_TOGGLE")
  SET_SCREENLOCK_DELAY=$(read_default screenLockDelay "$LIDLESS_SCREENLOCK_DELAY")
  SET_KEEP_AWAKE_ON_BATTERY=$(read_default keepAwakeOnBattery "$ENABLE_KEEP_AWAKE_ON_BATTERY")
  SET_STOP_ALL_CAFFEINATE=$(read_default stopAllCaffeinate "$ENABLE_STOP_ALL_CAFFEINATE")
  SET_SHUTDOWN_AFTER_HOURS=$(read_default automaticShutdownAfterHoursV1 "$SHUTDOWN_AFTER_HOURS_DEFAULT")
  SET_SHUTDOWN_BELOW_BATTERY_PERCENT=$(read_default automaticShutdownBelowBatteryPercentV1 "$SHUTDOWN_BELOW_BATTERY_PERCENT_DEFAULT")
  # No script fallback constant for either: absent means the app's own default,
  # not a value this script chose.
  SET_BLACKOUT_BUILTIN_DISPLAY=$(read_default blackoutBuiltinDisplayV1 0)
  SET_PANEL_MODE=$(panel_mode_value "$(read_default_raw panelModeV1)")

  app_setting_values="$(read_default_raw lowPowerWhileActive)"
  app_setting_values="$app_setting_values$(read_default_raw relaxScreenLock)"
  app_setting_values="$app_setting_values$(read_default_raw automaticShutdownAfterHoursV1)"
  app_setting_values="$app_setting_values$(read_default_raw automaticShutdownBelowBatteryPercentV1)"
  if [ -n "$app_setting_values" ]; then
    SETTINGS_SOURCE="app ($DEFAULTS_DOMAIN)"
  else
    SETTINGS_SOURCE="fallbacks in $(basename "$0")"
  fi
}

is_positive_int() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    0) return 1 ;;
    *) return 0 ;;
  esac
}

# A positive integer AND plausible as a Unix epoch — 10 digits or fewer,
# comfortably covering real timestamps into the year 2286 while staying well
# inside bash's 64-bit arithmetic range. auto_off_reason and
# resolve_started_at() both do arithmetic directly on this value; an
# oversized digit string (a corrupted state file, not a real timestamp)
# could otherwise wrap silently instead of being cleanly rejected. See
# docs/ARCHITECTURE.md — review round 1.
is_plausible_epoch() {
  is_positive_int "$1" && [ "${#1}" -le 10 ]
}

# auto_off_reason <enabled_epoch|""> <now_epoch> <on_battery 0|1> <percent|"">
#
# Prints why Lidless should switch itself off, or nothing if it should stay
# on. Pure: every input is a parameter, so tests can drive it without waiting
# hours or draining a battery. `started` is assumed already resolved — see
# resolve_started_at() below for how a corrupted future timestamp is repaired
# before it ever reaches this function.
auto_off_reason() {
  local started="$1" now="$2" onbatt="$3" percent="$4" elapsed

  if is_positive_int "$SET_SHUTDOWN_AFTER_HOURS" && is_plausible_epoch "$started"; then
    elapsed=$(( (now - started) / 3600 ))
    if [ "$elapsed" -ge "$SET_SHUTDOWN_AFTER_HOURS" ]; then
      echo "on for ${elapsed}h (limit ${SET_SHUTDOWN_AFTER_HOURS}h)"
      return 0
    fi
  fi

  # Only meaningful while actually discharging: a Mac on AC at 20% is charging.
  if is_positive_int "$SET_SHUTDOWN_BELOW_BATTERY_PERCENT" && [ "$onbatt" = "1" ] \
     && is_positive_int "$percent"; then
    if [ "$percent" -le "$SET_SHUTDOWN_BELOW_BATTERY_PERCENT" ]; then
      echo "battery at ${percent}% (limit ${SET_SHUTDOWN_BELOW_BATTERY_PERCENT}%)"
      return 0
    fi
  fi
}

# resolve_started_at <positive-int epoch> <now_epoch>
#
# Prints "<epoch> repaired" when `raw` sits more than ENABLED_AT_FUTURE_TOLERANCE
# seconds in the future (a corrupted timestamp, not ordinary clock skew) — the
# caller should rewrite ENABLEDAT_FILE to the printed epoch and log the repair.
# Otherwise prints "<raw> unchanged". Pure, like auto_off_reason above; only
# ever called with an already-validated positive-int `raw` (the caller checks
# is_positive_int first — an absent/junk timestamp has nothing to repair, it
# already reads as "no start time" to auto_off_reason).
#
# Mirrors Sources/main.swift's ensureEnabledAt: a far-future timestamp is
# repaired to now (restarting the auto-off window), not left to silently
# suppress the hours guard forever.
resolve_started_at() {
  local raw="$1" now="$2"
  if [ $(( raw - now )) -gt "$ENABLED_AT_FUTURE_TOLERANCE" ]; then
    printf '%s repaired\n' "$now"
  else
    printf '%s unchanged\n' "$raw"
  fi
}

# is_new_session <initial_lid: ignored|normal|unknown> <session_was_caffeinated: 0|1>
#
# True (exit 0) when this on() call is starting a genuinely new session — the
# lid was NOT already ignored and caffeinate was NOT already running before
# this call. A pure, directly-testable extraction of the decision
# on() uses to decide whether an existing ENABLEDAT_FILE (even one holding a
# perfectly valid, parseable timestamp) is stale and must be reset, rather
# than preserved. Mirrors Sources/main.swift's `sessionWasInactive`. See
# docs/ARCHITECTURE.md — review round 11.
is_new_session() {
  local initial_lid="$1" session_was_caffeinated="$2"
  [ "$initial_lid" != "ignored" ] && [ "$session_was_caffeinated" = "0" ]
}

# Writes the shared session timestamp once. The caller deliberately treats a
# write failure as non-fatal because the core lid/caffeinate state may already
# be active; this function still returns non-zero so tests and future callers
# can distinguish the degraded watchdog state.
record_enabled_at() {
  [ -f "$ENABLEDAT_FILE" ] && return 0
  if date +%s > "$ENABLEDAT_FILE" 2>/dev/null; then
    return 0
  fi
  echo "Could not write the auto-off timestamp — the auto-off watchdog may not track this session correctly." >&2
  return 1
}

# ---------------------------------------------------------------------------
# Probes
# ---------------------------------------------------------------------------

# Runs a command as root.
#
# From a terminal, sudo prompts for the password itself as usual. With no
# terminal — a LaunchAgent, for instance — there is nobody to type it, so use
# sudo -n and fail cleanly rather than hang forever on a prompt no one can see.
# The optional sudoers rule in the README is what makes that path succeed.
#
# This script never reads, stores or forwards a password in either case.
run_privileged() {
  if have_tty; then
    sudo "$@"
  else
    sudo -n "$@"
  fi
}

# Restore the two small, line-oriented session markers staged by
# automatic_shutdown(). The values are validated by their eventual readers;
# this function's job is lossless retry bookkeeping, not interpretation.
restore_shutdown_session_files() {
  local had_pid="$1" pid_backup="$2" had_enabled_at="$3" enabled_at_backup="$4"
  local had_lowpower="${5:-0}" lowpower_backup="${6:-}"

  if [ "$had_pid" = "1" ]; then
    printf '%s\n' "$pid_backup" > "$PID_FILE" || true
  fi
  if [ "$had_enabled_at" = "1" ]; then
    printf '%s\n' "$enabled_at_backup" > "$ENABLEDAT_FILE" || true
  fi
  if [ "$had_lowpower" = "1" ]; then
    printf '%s\n' "$lowpower_backup" > "$LOWPOWER_FILE" || true
  fi
}

screenlock_is_safe_for_automatic_shutdown() {
  local saved current

  [ -f "$SCREENLOCK_FILE" ] || return 0
  saved="$(validate_saved_screenlock "$(cat "$SCREENLOCK_FILE")")" || return 1
  current="$(read_screenlock)"
  [ "$current" = "$saved" ] || return 1
  rm -f "$SCREENLOCK_FILE"
}

restore_lowpower_for_automatic_shutdown() {
  local saved values ac battery presence

  [ -f "$LOWPOWER_FILE" ] || return 2
  saved="$(cat "$LOWPOWER_FILE")" || {
    AUTOMATIC_SHUTDOWN_WARNING="Could not read the saved Low Power Mode restore point."
    return 1
  }
  values="$(validate_saved_lowpower "$saved")" || {
    AUTOMATIC_SHUTDOWN_WARNING="Saved Low Power Mode state is invalid; its restore point was kept."
    return 1
  }
  read -r ac battery <<< "$values"
  presence="$(battery_presence)"
  if [ "$presence" = "unknown" ]; then
    AUTOMATIC_SHUTDOWN_WARNING="Low Power Mode was not restored because battery presence was unreadable; its restore point was kept."
    return 1
  fi

  if ! run_privileged pmset -c lowpowermode "$ac"; then
    AUTOMATIC_SHUTDOWN_WARNING="Low Power Mode on AC was not restored; its restore point was kept."
    return 1
  fi
  if [ "$presence" = "yes" ] && ! run_privileged pmset -b lowpowermode "$battery"; then
    AUTOMATIC_SHUTDOWN_WARNING="Low Power Mode on battery was not restored; its restore point was kept."
    return 1
  fi
  return 0
}

automatic_shutdown_helper_is_current() {
  local line expected

  expected="LIDLESS_POWEROFF_VERSION=\"$AUTOMATIC_SHUTDOWN_HELPER_VERSION\""
  [ -r "$AUTOMATIC_SHUTDOWN_HELPER_VERSION_CHECK_PATH" ] || return 1
  while IFS= read -r line; do
    [ "$line" = "$expected" ] && return 0
  done < "$AUTOMATIC_SHUTDOWN_HELPER_VERSION_CHECK_PATH"
  return 1
}

# Request a real system power-off without leaving session evidence that could
# retrigger the same expired limit after the next boot. Files are restored when
# sudoers denies the helper or the helper rejects the shutdown.
automatic_shutdown() {
  local had_pid=0 had_enabled_at=0 had_lowpower=0
  local pid_backup="" enabled_at_backup="" lowpower_backup=""
  local lowpower_restored=0

  AUTOMATIC_SHUTDOWN_WARNING=""
  if ! automatic_shutdown_helper_is_current; then
    echo "Automatic shutdown helper is missing or outdated; run tools/install-auto-shutdown.sh." >&2
    return 1
  fi
  if ! screenlock_is_safe_for_automatic_shutdown; then
    echo "Automatic shutdown cancelled: screen lock still needs an interactive restore." >&2
    return 78
  fi

  if restore_lowpower_for_automatic_shutdown; then
    lowpower_restored=1
    lowpower_backup="$(cat "$LOWPOWER_FILE")" || return 1
    had_lowpower=1
  else
    case "$?" in
      2) : ;;
      *) [ -n "$AUTOMATIC_SHUTDOWN_WARNING" ] && echo "$AUTOMATIC_SHUTDOWN_WARNING" >&2 ;;
    esac
  fi

  if [ -f "$PID_FILE" ]; then
    pid_backup="$(cat "$PID_FILE")" || return 1
    had_pid=1
  fi
  if [ -f "$ENABLEDAT_FILE" ]; then
    enabled_at_backup="$(cat "$ENABLEDAT_FILE")" || return 1
    had_enabled_at=1
  fi

  if ! rm -f "$PID_FILE" "$ENABLEDAT_FILE" || {
    [ "$lowpower_restored" = "1" ] && ! rm -f "$LOWPOWER_FILE"
  }; then
    restore_shutdown_session_files \
      "$had_pid" "$pid_backup" "$had_enabled_at" "$enabled_at_backup" \
      "$had_lowpower" "$lowpower_backup"
    if [ "$lowpower_restored" = "1" ] && truthy "$SET_LOW_POWER"; then
      run_privileged pmset -a lowpowermode 1 >/dev/null 2>&1 || true
    fi
    echo "Could not clear Lidless session files before shutdown." >&2
    return 1
  fi

  if run_privileged "$AUTOMATIC_SHUTDOWN_HELPER"; then
    return 0
  fi

  restore_shutdown_session_files \
    "$had_pid" "$pid_backup" "$had_enabled_at" "$enabled_at_backup" \
    "$had_lowpower" "$lowpower_backup"
  if [ "$lowpower_restored" = "1" ] && truthy "$SET_LOW_POWER"; then
    run_privileged pmset -a lowpowermode 1 >/dev/null 2>&1 || true
  fi
  return 1
}

# Is there a terminal to prompt on? Its own function so the interactive and
# non-interactive paths can be exercised separately: tests override it rather
# than trying to conjure a pty, which is not reliably available on a loaded
# machine or a CI runner.
have_tty() {
  [ -t 0 ]
}

# true only if PID_FILE holds a PID that is still actually a caffeinate process
# (guards against a stale/reused PID after reboot or crash)
# NOTE: none of these probes pipe into `grep -q`. Under `set -o pipefail` that
# combination reports failure even on a match: grep exits at the first hit, the
# producer dies of SIGPIPE, and pipefail surfaces the producer's status. Read the
# output into a variable and match it instead. `ioreg` output is tens of
# kilobytes, so has_lid() hit this every time on a Mac that does have a lid.
is_caffeinated() {
  [ -f "$PID_FILE" ] || return 1
  local pid
  pid=$(cat "$PID_FILE")
  is_caffeinate_pid "$pid"
}

# True only when one explicit PID currently belongs to caffeinate. Keeping the
# process-table check independent of PID_FILE lets stop-all verify every PID it
# signalled instead of trusting xargs/kill's exit status.
is_caffeinate_pid() {
  local pid="$1" comm
  case "$pid" in
    ''|0|*[!0-9]*) return 1 ;;
  esac
  comm=$(ps -p "$pid" -o comm= 2>/dev/null || true)
  # Exact basename, not a substring match — a stale/reused pid whose new
  # owner happens to be named e.g. "my-caffeinate-wrapper" must not pass.
  # Mirrors SystemProbe.isCaffeinateProcess's exact comparison.
  comm=${comm##*/}
  [ "$comm" = "caffeinate" ]
}

# Polls until PID_FILE identifies a live caffeinate process. `nohup command &`
# only proves that a child was spawned; the executable can fail or exit before
# on() reaches its success banner.
wait_for_caffeinate_start() {
  local attempt
  for (( attempt = 0; attempt < CAFFEINATE_EXIT_POLL_ATTEMPTS; attempt++ )); do
    is_caffeinated && return 0
    sleep "$CAFFEINATE_EXIT_POLL_SECONDS"
  done
  return 1
}

# Polls until `pid` is no longer a caffeinate process, or attempts run out.
# Used after `kill` instead of trusting its exit status — the same
# confirm-by-re-reading rule as set_screenlock/off()'s own lid-restore check.
wait_for_caffeinate_exit() {
  local pid="$1" attempt
  for (( attempt = 0; attempt < CAFFEINATE_EXIT_POLL_ATTEMPTS; attempt++ )); do
    is_caffeinate_pid "$pid" || return 0
    sleep "$CAFFEINATE_EXIT_POLL_SECONDS"
  done
  return 1
}

# SleepDisabled is what actually makes macOS ignore the lid switch.
# askForPassword in com.apple.screensaver is NOT used for this: since macOS
# Ventura the system ignores that plist key entirely (verify with
# `sysadminctl -screenLock status`, which reports the real value).
#
# Prints: ignored | normal | unknown. Every caller must handle all three
# explicitly — folding "unknown" into either boolean state is exactly the
# fail-open bug this function used to have (docs/ARCHITECTURE.md
# Phase 1).
lid_state() {
  local out
  out=$(pmset -g 2>/dev/null) || { echo "unknown"; return; }
  # Real output is never empty (see parse_sleep_disabled's comment on why a
  # missing key alone is not enough to call it unknown) — genuinely empty
  # stdout means the probe produced nothing, not that the lid is normal.
  [ -n "$out" ] || { echo "unknown"; return; }
  printf '%s' "$out" | parse_sleep_disabled
}

# Prints: ac | battery | unknown. A failed/empty `pmset -g ps` used to read
# indistinguishably from "confirmed on AC" — callers that skip an action on
# "unknown" (auto_off_reason's battery branch) depend on this distinction.
power_source() {
  # Exactly one whole line matching the canonical phrase, not a substring
  # match anywhere in the text — a `*"Now drawing from 'AC Power'"*` glob
  # would still accept a diagnostic message that happens to quote the same
  # phrase, or (with the Battery check first) silently prefer "battery" if
  # both phrases somehow appear. Requiring exactly one matching line rejects
  # zero matches, unrelated text, AND contradictory/duplicate output. See
  # docs/ARCHITECTURE.md — review round 3 (round 2's fix
  # anchored on the phrase but was still a substring match).
  local out
  out=$(pmset -g ps 2>/dev/null) || { echo "unknown"; return; }
  power_source_from "$out"
}

# Same matching logic as power_source(), but over an already-captured
# `pmset -g ps` snapshot — lets a caller that also needs the battery
# percentage (tools/lidless-check.sh) read the source and the percentage
# from one snapshot instead of two separate `pmset` calls, which a
# plug/unplug transition between the two reads could make disagree (e.g.
# "battery" from the first read paired with an AC percentage from the
# second). review round 4.
power_source_from() {
  local out="$1" line matches=0 result="unknown"
  while IFS= read -r line; do
    case "$line" in
      "Now drawing from 'Battery Power'") matches=$((matches + 1)); result="battery" ;;
      "Now drawing from 'AC Power'") matches=$((matches + 1)); result="ac" ;;
    esac
  done <<< "$out"
  if [ "$matches" -eq 1 ]; then
    echo "$result"
  else
    echo "unknown"
  fi
}

# Wraps a function call so a concurrent `on`/`off` — from the CLI, the app, or
# the watchdog — cannot race on stale state and start two caffeinate
# processes. /usr/bin/lockf -t 0 <fd> is used rather than a hand-rolled
# PID-file scheme: it wraps the real flock(2) kernel lock (confirmed by its
# own man page and verified empirically against Sources/SystemProbe.swift's
# native flock() call — the same mechanism on both sides, not two protocols
# that could silently diverge), so a crashed holder's lock is released by the
# kernel the instant its file descriptor closes — no manual stale-lock
# detection needed. flock(1) itself does not exist on macOS; shlock(1) does,
# but empirically does NOT reclaim a stale lock from a dead pid on this
# system despite what its man page claims (verified during Phase 4
# implementation) — do not switch back to it without re-verifying. See
# docs/ARCHITECTURE.md.
with_lock() {
  # Close fd 9 first: if it were somehow already open (inherited from a
  # caller), the `exec 9>>` below would silently reuse that existing
  # descriptor instead of opening $LOCK_FILE, and lockf would then lock
  # whatever that fd actually pointed at — not the Lidless lock. Closing an
  # already-closed fd is a harmless no-op (verified: bash's `exec 9>&-`
  # neither errors nor prints anything when fd 9 isn't open, so this needs no
  # error suppression — earlier this redirected `exec`'s own stderr to
  # /dev/null "just in case", which does not scope to this one statement:
  # `exec` with no command applies its redirections to the shell itself, so
  # that would have silently discarded every subsequent `>&2` message for the
  # rest of the process). Then validate the real open below explicitly
  # (under `set -e`, a bare failing `exec` would abort the whole script
  # rather than let this function report a clean error). See
  # docs/ARCHITECTURE.md — review round 4.
  exec 9>&-
  # `>>`, not `>` — non-truncating. If `$LOCK_FILE` were ever a symlink
  # (accidentally, or otherwise) pointing somewhere unexpected, a plain `>`
  # would truncate that target to zero bytes before locking even began.
  # Content here is irrelevant either way (only the fd matters), so `>>`
  # costs nothing and removes that failure mode. See
  # docs/ARCHITECTURE.md — review round 2.
  # Probe openability in a subshell first: `exec`'s redirections attach to
  # whatever shell runs it, so testing with a bare `exec 9>>... 2>/dev/null`
  # in *this* shell would, on the success path, permanently redirect this
  # shell's real stderr to /dev/null for the rest of the process the moment
  # the redirection actually succeeds (verified empirically — every `>&2`
  # message downstream, including off()'s own failure explanations, silently
  # vanished). The subshell's stderr suppression dies with the subshell; only
  # its exit status escapes.
  if ! ( exec 9>>"$LOCK_FILE" ) 2>/dev/null; then
    echo "Could not open the lock file ($LOCK_FILE) — try again." >&2
    return 1
  fi
  exec 9>>"$LOCK_FILE"
  # Propagate lockf's own exit code (EX_TEMPFAIL/75 for "already locked")
  # rather than collapsing to a plain 1 — collapsing it made lock contention
  # indistinguishable from off()'s own hard failure (exit 1, "needs root") to
  # any caller that branches on the exit code, e.g. the watchdog. Captured via
  # && / || since a bare failing command would trip `set -e` in callers that
  # have it on. (review round 1.)
  local lock_rc
  /usr/bin/lockf -t 0 9 && lock_rc=0 || lock_rc=$?
  if [ "$lock_rc" -ne 0 ]; then
    echo "Another Lidless process is already enabling/disabling — try again in a moment." >&2
    exec 9>&-
    return "$lock_rc"
  fi
  trap 'exec 9>&-' RETURN
  "$@"
}

has_battery() {
  local out
  out=$(pmset -g custom 2>/dev/null || true)
  [[ "$out" == *"Battery Power"* ]]
}

# Prints: yes | no | unknown. Unlike has_battery (a plain boolean used for
# display, where folding a probe failure into "no battery" is low-stakes), a
# failed `pmset -g custom` here must NOT read as "confirmed desktop" — off()'s
# Low Power Mode restore uses this to decide whether to attempt the
# battery-side restore, and treating a failed probe as "no battery" used to
# skip that restore silently, then delete the saved value anyway, losing the
# battery-side setting permanently. See docs/ARCHITECTURE.md
# (extended here to the restore path, not just detection — review
# round 1).
# Validates a value read from .lidless_lowpower_prev ("ac:battery", each
# exactly 0 or 1). Prints "<ac> <battery>" (space-separated) if valid, prints
# nothing and returns 1 otherwise — mirrors
# Sources/SystemProbe.swift's savedLowPower(in:), which off() lacked
# (a corrupted file used to pass straight through to `pmset -c/-b
# lowpowermode` with whatever garbage was in it). See
# docs/ARCHITECTURE.md — review round 3.
validate_saved_lowpower() {
  local saved="$1"
  case "$saved" in
    0:0|0:1|1:0|1:1) : ;;
    *) return 1 ;;  # anything else — including a colonless "0"/"1", which
                     # %%/## would silently accept as ac==battery — is rejected
  esac
  printf '%s %s\n' "${saved%%:*}" "${saved##*:}"
}

# Validates a value read from .lidless_screenlock_prev: exactly "off",
# "immediate", or a non-negative integer — mirrors
# Sources/SystemProbe.swift's savedScreenLock(in:), which off() (and on()'s
# reuse of an existing file) lacked. A corrupted file used to pass straight
# through to `sysadminctl -screenLock <value> -password -` with whatever
# garbage it held, the same bug already fixed for Low Power Mode above.
# Prints the value if valid, prints nothing and returns 1 otherwise.
# Canonicalizes away leading zeros ("0900" -> "900"), matching Swift's
# Int("0900") == 900 (then re-stringified) — a non-canonical numeral used to
# pass through unchanged, so set_screenlock's own re-verification (which
# compares against real sysadminctl output, always canonical) could report
# failure even after successfully applying the value, stranding a good
# restore behind a false "partial" forever. See
# docs/ARCHITECTURE.md — review rounds 8 and 9.
validate_saved_screenlock() {
  local saved="$1"
  case "$saved" in
    off|immediate) printf '%s\n' "$saved"; return 0 ;;
    ''|*[!0-9]*) return 1 ;;
  esac
  # 19+ digits already exceeds Int64/Swift Int's range, which a real screen
  # lock delay (seconds) never approaches — rejected before doing arithmetic
  # on it rather than relying on bash's own overflow behavior.
  [ "${#saved}" -le 18 ] || return 1
  printf '%s\n' "$(( 10#$saved ))"
}

# Prints: yes | no | unknown, from `pmset -g batt`'s own text — but only
# trusts the reading if it also contains one of the canonical "Now drawing
# from '...'" lines power_source() itself requires. A status-0 call that
# returns malformed/unrecognizable text must not be read as "confirmed no
# battery" merely because it also lacks the word "InternalBattery" — that
# was still possible even after round 2's cross-check, which only checked
# the command's exit status, not whether its output was actually well-formed.
# See docs/ARCHITECTURE.md — review round 4.
battery_entry_presence() {
  local out
  out=$(pmset -g batt 2>/dev/null) || { echo "unknown"; return; }
  # power_source_from(), not a substring glob — a glob accepted duplicate or
  # contradictory canonical lines, or a diagnostic message merely quoting the
  # phrase, exactly the class of bug already fixed for power_source() itself
  # (and the parity Swift already had via powerSourceResult). review
  # round 5.
  case "$(power_source_from "$out")" in
    ac|battery) : ;;
    *) echo "unknown"; return ;;
  esac
  if [[ "$out" == *InternalBattery* ]]; then
    echo "yes"
  else
    echo "no"
  fi
}

battery_presence() {
  local out
  out=$(pmset -g custom 2>/dev/null) || { echo "unknown"; return; }
  if [[ "$out" == *"Battery Power"* ]]; then
    echo "yes"
    return
  fi
  if [[ "$out" != *"AC Power"* ]]; then
    echo "unknown"
    return
  fi
  # "AC Power" present but no "Battery Power" section could mean a genuine
  # desktop, but could also mean `pmset -g custom`'s output was truncated
  # right at the section boundary. Cross-check against a different,
  # independently-validated command before confidently saying "no": if it
  # cannot even produce a well-formed reading, or if it reports a real
  # battery, the two probes disagree (or neither confirms anything), and
  # "unknown" is the honest answer, not "no". See
  # docs/ARCHITECTURE.md — review rounds 2 and 4.
  case "$(battery_entry_presence)" in
    no) echo "no" ;;
    *) echo "unknown" ;;
  esac
}

has_lid() {
  local out
  out=$(ioreg -r -k AppleClamshellState 2>/dev/null || true)
  [[ "$out" == *AppleClamshellState* ]]
}

# Empty (no such power source) reads as 0 so saved state stays well-formed.
lowpower_or_zero() {
  local value="$1"
  echo "${value:-0}"
}

# Prints: 0 | 1 | unknown for one section's lowpowermode. The only reader of
# `pmset -g custom`'s lowpowermode value — `read_pmset_custom`,
# `read_lowpower_ac` and `read_lowpower_battery` were deleted on 2026-08-06.
# All three were transitively dead, and none of them was inert: they returned
# the old conflated result this function exists to replace, so anyone reaching
# for the obvious-looking name would have got the bug below back. A failed/malformed
# `pmset -g custom` must not read as "0" (confirmed off) — lowpower_or_zero's
# fallback is meant for "this power source doesn't exist" (a real, parseable
# empty), not "the probe failed"; conflating the two used to let on() silently
# save a fabricated "0" as the user's original value, which off() would later
# restore for real, discarding whatever it actually was. See
# docs/ARCHITECTURE.md — review round 2.
read_lowpower_value() {
  local section="$1" out value
  out=$(pmset -g custom 2>/dev/null) || { echo "unknown"; return; }
  [ -n "$out" ] || { echo "unknown"; return; }
  value=$(printf '%s' "$out" | parse_lowpower_field "$section")
  case "$value" in
    0|1) echo "$value" ;;
    *) echo "unknown" ;;
  esac
}

# Reads `pmset -g custom` exactly once and prints three lines: AC lowpowermode
# (0|1|unknown), battery presence (yes|no|unknown), battery lowpowermode
# (0|1|unknown — only meaningful when presence is "yes", "0" otherwise).
# on()'s save-before-enable logic used to call read_lowpower_value/
# battery_presence separately (three independent `pmset -g custom`
# shell-outs, and a presence "unknown" quietly fell through to "no battery",
# not "cannot confirm, do not save") — a single read fixes both. See
# docs/ARCHITECTURE.md — review round 3.
read_lowpower_snapshot() {
  local out ac presence battery
  out=$(pmset -g custom 2>/dev/null) || { echo "unknown"; echo "unknown"; echo "unknown"; return; }
  if [ -z "$out" ]; then
    echo "unknown"; echo "unknown"; echo "unknown"
    return
  fi

  ac=$(printf '%s' "$out" | parse_lowpower_field "AC Power")
  case "$ac" in
    0|1) : ;;
    *) ac="unknown" ;;
  esac

  if [[ "$out" == *"Battery Power"* ]]; then
    presence="yes"
    battery=$(printf '%s' "$out" | parse_lowpower_field "Battery Power")
    case "$battery" in
      0|1) : ;;
      *) battery="unknown" ;;
    esac
  elif [[ "$out" == *"AC Power"* ]]; then
    # Same cross-check as battery_presence() — "no Battery Power section"
    # alone is not enough to confirm a desktop; a truncated read looks
    # identical. review round 4 caught that this function had its
    # own inline copy of the pre-round-4 (uncross-checked) logic.
    case "$(battery_entry_presence)" in
      no) presence="no"; battery="0" ;;
      *) presence="unknown"; battery="unknown" ;;
    esac
  else
    presence="unknown"
    battery="unknown"
  fi

  echo "$ac"
  echo "$presence"
  echo "$battery"
}

# By default, stops only the process this tool started. Other caffeinate
# processes may belong to a build, a download or another app, so they are
# reported and left alone unless the explicit stop-all option is enabled.
#
# Returns 1 if the managed process was still alive after kill+poll — verified
# by re-reading the process table, never by kill's own exit status (the same
# rule set_screenlock/off()'s lid-restore check already follow). On confirmed
# failure the pid file is deliberately KEPT rather than removed: the process
# is still ours and still running, so losing track of it here would be the
# same orphan-tracking bug this whole plan exists to close, just one level
# down. When stop-all is enabled, its PIDs are polled as a group and any
# confirmed survivor also makes the operation partial instead of being reported
# as stopped unconditionally.
stop_our_caffeinate() {
  local status=0
  if is_caffeinated; then
    local pid
    pid=$(cat "$PID_FILE")
    kill "$pid" 2>/dev/null || true
    if wait_for_caffeinate_exit "$pid"; then
      echo "caffeinate stopped (pid $pid)"
      rm -f "$PID_FILE"
    else
      echo "COULD NOT confirm caffeinate (pid $pid) stopped — leaving it tracked." >&2
      status=1
    fi
  else
    echo "caffeinate was not running"
    rm -f "$PID_FILE"
  fi

  local others pgrep_status
  if others=$(pgrep -u "$(id -u)" -x caffeinate 2>/dev/null); then
    pgrep_status=0
  else
    pgrep_status=$?
  fi

  # pgrep uses 1 for the ordinary "no matches" result. Any other failure
  # means stop-all could not even establish its target set and therefore must
  # not be reported as a complete success. The default, managed-only path does
  # not promise to enumerate unrelated processes, so it preserves its own
  # result when this optional diagnostic probe is unavailable.
  if [ "$pgrep_status" -ne 0 ]; then
    if [ "$pgrep_status" -ne 1 ] && truthy "$SET_STOP_ALL_CAFFEINATE"; then
      echo "COULD NOT enumerate current caffeinate processes for stop-all (pgrep exit $pgrep_status)." >&2
      return 1
    fi
    return "$status"
  fi
  [ -n "$others" ] || {
    if truthy "$SET_STOP_ALL_CAFFEINATE"; then
      echo "COULD NOT enumerate current caffeinate processes for stop-all (pgrep returned no PIDs with success)." >&2
      return 1
    fi
    return "$status"
  }

  if truthy "$SET_STOP_ALL_CAFFEINATE"; then
    echo "$others" | xargs kill 2>/dev/null || true
    # Poll all signalled PIDs as one group. Polling each PID separately would
    # make Disable take up to N seconds for N processes; this keeps the upper
    # bound at the same ~1 second used for the managed process.
    local attempt pid remaining="$others"
    for (( attempt = 0; attempt < CAFFEINATE_EXIT_POLL_ATTEMPTS; attempt++ )); do
      remaining=""
      while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        if is_caffeinate_pid "$pid"; then
          remaining="${remaining}${remaining:+ }$pid"
        fi
      done <<< "$others"
      [ -n "$remaining" ] || break
      sleep "$CAFFEINATE_EXIT_POLL_SECONDS"
    done

    # The managed PID and the unrelated PIDs have independent outcomes. If
    # stop-all killed our process after its first dedicated poll timed out,
    # remove its now-stale PID file even when a different caffeinate process
    # survived and the overall operation must still be reported as partial.
    if [ "$status" -ne 0 ] && [ -f "$PID_FILE" ] && ! is_caffeinated; then
      rm -f "$PID_FILE"
      status=0
    fi

    if [ -n "$remaining" ]; then
      echo "COULD NOT confirm these caffeinate processes stopped: $remaining" >&2
      status=1
    else
      echo "also stopped other caffeinate processes: $(echo "$others" | tr '\n' ' ')"
    fi
  else
    echo "note: other caffeinate processes are still running and were left alone:"
    echo "      $(echo "$others" | tr '\n' ' ')"
    echo "      stop them yourself if they are leftovers: kill $(echo "$others" | tr '\n' ' ')"
  fi
  return "$status"
}

# Prints the current screen lock delay as: off | immediate | <seconds> | unknown
read_screenlock() {
  local out
  out=$(sysadminctl -screenLock status 2>&1) || true
  parse_screenlock <<<"$out"
}

# sysadminctl only accepts the password interactively ('-password -'), so this
# needs a real terminal. Never pass the password as an argument: it would land
# in shell history and in `ps` output.
#
# Success is decided by re-reading the value afterwards, NOT by the exit status:
# sysadminctl exits 0 and prints "Password is required!" to stderr, so a wrong or
# missing password looks like success to `if`.
set_screenlock() {
  local value="$1"
  if ! have_tty; then
    echo "SKIPPED screen lock ($value): needs a terminal for the password prompt"
    return 1
  fi
  echo "Setting screen lock delay to $value (password prompt follows)..."
  sysadminctl -screenLock "$value" -password - || true

  if [ "$(read_screenlock)" = "$value" ]; then
    return 0
  fi
  echo "Screen lock is still $(read_screenlock), not $value — not applied."
  return 1
}

on() {
  load_settings
  cancel_pending_shutdown >/dev/null 2>&1 || true
  echo "Settings from: $SETTINGS_SOURCE"

  # Captured before anything below can change it — used later to decide
  # whether this is a genuinely new session (mirrors Sources/main.swift's
  # sessionWasInactive).
  local session_was_caffeinated=0
  if is_caffeinated; then
    session_was_caffeinated=1
    echo "caffeinate already running (pid $(cat "$PID_FILE"))"
  else
    rm -f "$PID_FILE"
    # -s alone is honoured only on AC power, so on battery it does nothing.
    # -i adds the power-source-independent assertion.
    local flags="-s"
    if truthy "$SET_KEEP_AWAKE_ON_BATTERY"; then flags="-si"; fi
    # `9>&-` closes the interprocess lock's descriptor in the child, and it is
    # not optional. `on()` runs under `with_lock`, which holds the lock on fd 9;
    # a child started without this inherits that descriptor, and a `lockf`/`flock`
    # lock is released only when EVERY descriptor referring to the file is
    # closed. `caffeinate` outlives `on()` by design, so the lock stayed held for
    # as long as Lidless was on — measured 2026-08-04, `lsof ~/.lidless_lock`
    # showing `caffeinat ... 9w`.
    #
    # What that cost: every later `with_lock` caller failed with EX_TEMPFAIL for
    # the whole session — `off` could not run, and the app's automatic panel
    # blackout gave up silently at its own lock acquisition. It looked like the
    # blackout was broken; the lock was.
    nohup caffeinate "$flags" >/dev/null 2>&1 9>&- &
    disown
    local new_pid=$!
    # Checked explicitly, not a bare redirect — under `set -e`, a failed write
    # here (e.g. $HOME unwritable) would abort `on()` on the spot with a
    # caffeinate process already running and untracked: exactly the orphaning
    # this tool exists to prevent, just one level down. If we can't track it,
    # stop it rather than leave an untracked process behind. review
    # round 6.
    if ! echo "$new_pid" > "$PID_FILE" 2>/dev/null; then
      kill "$new_pid" 2>/dev/null || true
      # Confirmed by re-reading the process table, not by kill's own exit
      # status — the same rule this file already applies everywhere else
      # (docs/ARCHITECTURE.md), extended here to the cleanup path itself. review
      #  round 7 caught that this used to claim "stopped it for
      # safety" unconditionally right after an unverified `kill`.
      if wait_for_caffeinate_exit "$new_pid"; then
        echo "Could not record the new caffeinate process (pid $new_pid) — stopped it for safety. Is \$HOME writable?" >&2
      else
        echo "Could not record the new caffeinate process (pid $new_pid), AND could not confirm it was stopped — it may still be running untracked. Is \$HOME writable?" >&2
      fi
      return 1
    fi
    echo "caffeinate $flags started (pid $(cat "$PID_FILE"))"
  fi

  # Success is decided by re-reading the value afterwards, never by
  # run_privileged's exit status alone (docs/ARCHITECTURE.md's rule, extended
  # from sysadminctl to pmset, already applied to off()'s lid restore — on()
  # printed an unconditional "will now be ignored" regardless of whether the
  # privileged command actually succeeded or the value actually moved, until
  # review round 3 caught the parity gap).
  local initial_lid lid_confirmed=1
  initial_lid="$(lid_state)"

  # Discarded here — before the lid step below, which can fail and `return 1`
  # early, deliberately leaving a freshly-started caffeinate running for
  # safety — not down near the final timestamp write. review round
  # 12 caught that discarding it only at the end meant a failed first attempt
  # left the stale file in place; a retried `on` would then see caffeinate
  # already running from the failed attempt (session_was_caffeinated=1) and
  # is_new_session would report false, wrongly preserving the stale
  # timestamp across what the user experiences as one new session that
  # merely needed two tries. Discarding it this early means the retry's own
  # "write if absent" always creates a fresh one regardless of how
  # is_new_session evaluates on that second call.
  if [ -f "$ENABLEDAT_FILE" ] && { is_new_session "$initial_lid" "$session_was_caffeinated" \
       || ! is_plausible_epoch "$(cat "$ENABLEDAT_FILE" 2>/dev/null)"; }; then
    rm -f "$ENABLEDAT_FILE"
  fi

  if [ "$initial_lid" = "ignored" ]; then
    echo "Lid close already ignored (SleepDisabled=1)"
  else
    # Attempting the change is safe even if it was already applied; skipping
    # it because the probe was unreadable is not — that is the same
    # fail-open this project has been bitten by before (docs/ARCHITECTURE.md).
    if [ "$initial_lid" = "unknown" ]; then
      echo "Could not read the current lid setting — applying it anyway to be safe." >&2
    fi
    if run_privileged pmset -a disablesleep 1 && [ "$(lid_state)" = "ignored" ]; then
      echo "Lid close will now be ignored (SleepDisabled=1)"
    else
      echo "COULD NOT confirm the lid setting was applied — that needs root, or the change did not take." >&2
      if [ ! -t 0 ]; then
        echo "      Running without a terminal, so sudo could not ask for a password." >&2
        echo "      Install the sudoers rule from the README to allow this silently." >&2
      fi
      lid_confirmed=0
    fi
  fi

  # An unconfirmed lid setting must not fall through to the rest of on()'s
  # work, the auto-off timestamp, or the "Lidless is ON" success banner — the
  # one thing this tool cannot claim without proof. caffeinate (if this call
  # started it) is deliberately left running rather than rolled back: it is
  # the safer default absent a clearer signal either way, and rollback
  # correctness on an "unknown" lid state is its own trap (see the sibling
  # Swift finding, review round 4). Run 'off' or 'on' again once the
  # underlying problem (usually: needs the sudoers rule, or a terminal) is fixed.
  if [ "$lid_confirmed" = "0" ]; then
    echo "      caffeinate was left running for safety; run '$(basename "$0") off' to stop it, or try 'on' again." >&2
    return 1
  fi

  # Record the safety deadline immediately after the persistent lid setting is
  # confirmed. Optional features and the final caffeinate verification must not
  # prevent the unattended watchdog from tracking a partially-started session.
  record_enabled_at || true

  # `nohup caffeinate ... &` only proves that a child process was created. The
  # executable can fail or exit immediately, so confirm the PID still belongs
  # to caffeinate before applying optional settings or claiming Lidless is ON.
  if ! wait_for_caffeinate_start; then
    # The process table has repeatedly confirmed that this PID is no longer a
    # caffeinate. Keeping the number would be dangerous: after PID reuse, a
    # later managed-only Disable could mistake somebody else's caffeinate for
    # ours. Keep the session timestamp (the persistent lid setting is active),
    # but discard the known-stale PID.
    if rm -f "$PID_FILE"; then
      echo "Lid sleep is disabled, but caffeinate did not stay running. Its stale PID was cleared and the safety timestamp was kept; run '$(basename "$0") off'." >&2
    else
      echo "Lid sleep is disabled and caffeinate did not stay running, but its stale PID file could not be removed. Remove $PID_FILE before PID reuse, then run '$(basename "$0") off'." >&2
    fi
    return 1
  fi

  if truthy "$SET_LOW_POWER"; then
    # A pre-existing LOWPOWER_FILE is only a trustworthy restore point if it's
    # actually well-formed — off() already refuses to restore from anything
    # validate_saved_lowpower rejects, so an existing-but-corrupt file must be
    # treated the same as "no file", not blindly trusted. See
    # docs/ARCHITECTURE.md — review round 4.
    if [ -f "$LOWPOWER_FILE" ] && ! validate_saved_lowpower "$(cat "$LOWPOWER_FILE")" >/dev/null; then
      echo "Saved Low Power Mode state ($LOWPOWER_FILE) is malformed — recapturing it." >&2
      rm -f "$LOWPOWER_FILE"
    fi
    # `if run_privileged ...; then/else` below, not a bare statement — under
    # `set -e`, a bare `run_privileged pmset -a lowpowermode 1` that fails
    # (e.g. the sudoers rule only covers `disablesleep`, or an interactive
    # sudo prompt is declined) kills the whole script on the spot: the
    # already-confirmed lid setting and the screen-lock save that follows would
    # never run, and `on` would exit with
    # no explanation at all. Verified empirically: a non-interactive script
    # reproducing this exact sequence died silently right after sudo's
    # denial, before printing anything else. This is optional, comfort-level
    # functionality — its failure must not take down the safety-critical
    # parts of `on()` that come after it. See
    # docs/ARCHITECTURE.md — review round 5.
    if [ -f "$LOWPOWER_FILE" ]; then
      if run_privileged pmset -a lowpowermode 1; then
        echo "Low Power Mode on"
      else
        echo "Low Power Mode could NOT be enabled — that needs root, or the change did not take. Continuing without it." >&2
      fi
    else
      # Do not save (or enable, without a trustworthy restore point) unless
      # every value is confirmed — including battery presence itself, which
      # used to fall through to "no battery" (default 0) on "unknown" too.
      local lp_ac lp_presence lp_battery
      { read -r lp_ac; read -r lp_presence; read -r lp_battery; } < <(read_lowpower_snapshot)
      if [ "$lp_ac" = "unknown" ] || [ "$lp_presence" = "unknown" ] || [ "$lp_battery" = "unknown" ]; then
        echo "Could not read the current Low Power Mode — leaving it unchanged this time." >&2
      # Checked explicitly, not a bare redirect — a failed write here (e.g.
      # $HOME unwritable) would otherwise abort `on()` right before the
      # already-fixed guard below even gets a chance to run. review
      # round 6.
      elif ! echo "$lp_ac:$lp_battery" > "$LOWPOWER_FILE" 2>/dev/null; then
        echo "Could not save the current Low Power Mode as a restore point — leaving it unchanged this time." >&2
      else
        echo "Saved original Low Power Mode: $(cat "$LOWPOWER_FILE") (ac:battery)"
        if run_privileged pmset -a lowpowermode 1; then
          echo "Low Power Mode on"
        else
          echo "Low Power Mode could NOT be enabled — that needs root, or the change did not take. Continuing without it." >&2
        fi
      fi
    fi
  fi

  if truthy "$SET_SCREENLOCK" && {
    is_positive_int "$SET_SHUTDOWN_AFTER_HOURS" ||
      is_positive_int "$SET_SHUTDOWN_BELOW_BATTERY_PERCENT"
  }; then
    echo "SKIPPED screen-lock relaxation: it cannot be restored unattended before automatic shutdown." >&2
  elif truthy "$SET_SCREENLOCK"; then
    # Save the original delay once, so repeated `on` runs cannot overwrite it
    # with the already-relaxed value. Relaxing the lock is only attempted when
    # a restore point actually exists (pre-existing or freshly saved) — review
    #  round 7 caught that this used to call `set_screenlock`
    # unconditionally even when the original value was unreadable or the save
    # failed, mutating a persistent setting with no way back. Same fail-safe
    # philosophy already applied to Low Power Mode above.
    local have_screenlock_restore=0
    # A pre-existing file is only a trustworthy restore point if it's
    # actually well-formed — off() refuses to restore from anything
    # validate_saved_screenlock rejects (see below), so an existing-but-corrupt
    # file must be treated the same as "no file", not blindly trusted. Mirrors
    # the same fix already applied to LOWPOWER_FILE. review round 8.
    if [ -f "$SCREENLOCK_FILE" ] && ! validate_saved_screenlock "$(cat "$SCREENLOCK_FILE")" >/dev/null; then
      echo "Saved screen lock state ($SCREENLOCK_FILE) is malformed — recapturing it." >&2
      rm -f "$SCREENLOCK_FILE"
    fi
    if [ -f "$SCREENLOCK_FILE" ]; then
      echo "Original screen lock delay already saved: $(cat "$SCREENLOCK_FILE")"
      have_screenlock_restore=1
    else
      local prev
      prev=$(read_screenlock)
      # Never save "unknown": `off` would later try to restore it as a literal
      # value and strand the relaxed delay.
      if [ -n "$prev" ] && [ "$prev" != "unknown" ]; then
        # Checked, not bare — same class of bug as the Low Power Mode save
        # above: a failed write here must not abort the rest of `on()`.
        if echo "$prev" > "$SCREENLOCK_FILE" 2>/dev/null; then
          echo "Saved original screen lock delay: $prev"
          have_screenlock_restore=1
        else
          echo "Could not save the original screen lock delay — leaving it unchanged this time." >&2
        fi
      else
        echo "Could not read the current screen lock delay — leaving it unchanged this time." >&2
      fi
    fi
    if [ "$have_screenlock_restore" = "1" ]; then
      set_screenlock "$(screenlock_target "$SET_SCREENLOCK_DELAY")" || true
    fi
  fi

  echo
  echo "Lidless is ON. This Mac will NOT sleep when the lid is closed."
  echo "Run '$(basename "$0") off' before putting it in a bag."
}

# Exit codes: 0 = fully restored. 1 = hard failure — the lid setting itself
# could not be restored (or confirmed restored), the one thing this tool
# treats as fatal since it is what quietly cooks a Mac in a bag. 2 = partial —
# the lid *was* restored, but Low Power Mode and/or the screen lock delay
# and/or stopping caffeinate was not — per Phase 8. Callers (the watchdog)
# must not report a plain "succeeded" for code 2 — see
# docs/ARCHITECTURE.md.
off() {
  load_settings
  cancel_pending_shutdown >/dev/null 2>&1 || true
  local partial=0

  # Lid first: a Mac that ignores the lid is the state that quietly cooks in a
  # bag, so restore it before anything that could fail or be cancelled.
  #
  # "unknown" must NOT be treated as "already normal" — attempting a restore
  # that turns out to have been unnecessary is a harmless no-op; skipping one
  # that was actually needed is the real danger. Either way, success is
  # decided by re-reading the value afterwards, never by pmset's exit status
  # (docs/ARCHITECTURE.md's rule, extended here from sysadminctl to pmset — a
  # command reporting success does not guarantee the value actually moved).
  local initial
  initial="$(lid_state)"
  if [ "$initial" = "normal" ]; then
    echo "Lid behaviour already normal (SleepDisabled=0)"
  else
    if [ "$initial" = "unknown" ]; then
      echo "Could not read the current lid setting — attempting to restore normal behaviour anyway." >&2
    fi
    if run_privileged pmset -a disablesleep 0 && [ "$(lid_state)" = "normal" ]; then
      echo "Normal lid behaviour restored (SleepDisabled=0)"
    else
      echo "COULD NOT restore lid behaviour — that needs root, or the change did not take." >&2
      if [ ! -t 0 ]; then
        echo "      Running without a terminal, so sudo could not ask for a password." >&2
        echo "      Install the sudoers rule from the README to allow this silently." >&2
      fi
      echo "      Nothing else was changed. Run '$(basename "$0") off' from a terminal." >&2
      return 1
    fi
  fi

  # Restore power settings whenever a saved value exists, even if the option is
  # now disabled — otherwise turning the feature off would strand the change.
  if [ -f "$LOWPOWER_FILE" ]; then
    local saved ac="" battery="" restored=1 reason="" valid=1
    saved=$(cat "$LOWPOWER_FILE")
    if ! read -r ac battery < <(validate_saved_lowpower "$saved"); then
      # A corrupted file used to pass straight through to `pmset -c/-b
      # lowpowermode` with whatever garbage it held. Mirrors Swift's
      # savedLowPower(in:) validation. review round 3.
      valid=0
      restored=0
      reason="the saved state is invalid"
    fi

    if [ "$valid" = "1" ]; then
      if ! run_privileged pmset -c lowpowermode "$ac"; then
        restored=0
        reason="needs root, and no password can be asked for here"
      fi
      if [ "$restored" = "1" ]; then
        case "$(battery_presence)" in
          yes)
            if ! run_privileged pmset -b lowpowermode "$battery"; then
              restored=0
              reason="needs root, and no password can be asked for here"
            fi
            ;;
          unknown)
            # Do NOT fold this into "no battery, nothing else to do" — that
            # used to skip the battery-side restore silently and then delete
            # $LOWPOWER_FILE anyway, losing the saved battery value for good.
            restored=0
            reason="could not confirm whether this Mac has a battery"
            ;;
          no) : ;; # confirmed desktop — nothing else to restore
        esac
      fi
    fi

    if [ "$restored" = "1" ]; then
      rm -f "$LOWPOWER_FILE"
      echo "Low Power Mode restored (ac=$ac battery=$battery)"
    else
      # Not fatal — unlike the lid setting, Low Power Mode cannot cook a Mac
      # in a bag, it is a comfort setting. Keep the saved value (when valid)
      # so a later interactive `off` can still put it back. It DOES count
      # toward the `partial` tri-state below, per Phase 8's own definition
      # (an earlier revision excluded it and folded this into full success
      # instead — review round 1 pointed out that contradicted the
      # plan as written; aligning the code with the plan is the more honest
      # signal: "partial" is not an alarm, it just means something less
      # critical still needs attention).
      echo "Low Power Mode NOT restored: $reason." >&2
      if [ "$valid" = "1" ]; then
        echo "      Kept $LOWPOWER_FILE — run '$(basename "$0") off' from a terminal to finish." >&2
      fi
      partial=1
    fi
  fi

  # Re-check immediately before stopping caffeinate, not just right after the
  # initial restore attempt — the Low Power Mode/screen-lock work above takes
  # real time, during which something outside this tool's control (a manual
  # `pmset -a disablesleep 1`, say) could re-enable the lid setting. Stopping
  # caffeinate without catching that would create exactly the orphaned state
  # this tool exists to prevent. Mirrors Sources/main.swift's
  # lidBeforeCaffeinateStop check (review round 1 — Swift already
  # had this, shell did not).
  case "$(lid_state)" in
    normal) : ;;
    ignored)
      echo "Lid sleep became disabled again — caffeinate was left running for safety." >&2
      return 1
      ;;
    unknown)
      echo "Could not verify normal lid sleep before stopping caffeinate — caffeinate was left running for safety." >&2
      return 1
      ;;
  esac

  stop_our_caffeinate || partial=1
  rm -f "$ENABLEDAT_FILE"

  if [ -f "$SCREENLOCK_FILE" ]; then
    local prev
    # A corrupted file used to pass straight through to `sysadminctl
    # -screenLock <value> -password -` with whatever garbage it held — the
    # same bug already fixed for Low Power Mode's validate_saved_lowpower.
    # review round 8.
    if ! prev=$(validate_saved_screenlock "$(cat "$SCREENLOCK_FILE")"); then
      echo "Saved screen lock state ($SCREENLOCK_FILE) is invalid; it was left untouched." >&2
      partial=1
    elif set_screenlock "$prev"; then
      rm -f "$SCREENLOCK_FILE"
      echo "Screen lock delay restored to $prev"
    else
      echo "Kept $SCREENLOCK_FILE so the original value ($prev) is not lost"
      partial=1
    fi
  fi

  # Panel blackout is deliberately NOT restored here, and `on` deliberately does
  # not apply it. It is the one thing Lidless does that this script structurally
  # cannot own: the virtual display carrying the session lives exactly as long as
  # the process that created it, so a shell command would create it, switch the
  # panel off and then exit — undoing both a millisecond later and leaving a Mac
  # with no display at all in between. It belongs to the app, whose process stays
  # alive. See docs/ARCHITECTURE.md
  #
  # A crash mid-blackout is NOT self-healing — the disable of the built-in
  # outlives the process that made it (docs/ARCHITECTURE.md, measured). The app
  # runs a recovery watchdog for that, and `rescue-display` below is the way out
  # when even that is gone.
  [ "$partial" = "1" ] && return 2
  return 0
}

# Runs the app's recovery binary, which puts displays and backlights back.
#
# Not a reimplementation of it: it is a compiled tool because it has to work when
# the app is the thing that died, and every action it takes only ever makes a
# display APPEAR or a backlight come UP — safe to run twice, safe to run when
# nothing is wrong, safe to run with no idea what is wrong. That is the point,
# because whoever needs it cannot see the screen.
#
# Arguments are passed straight through, so `rescue-display --explain` reaches
# the tool's own read-only mode.
rescue_display() {
  local candidate
  for candidate in \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build/Lidless.app" \
    "/Applications/Lidless.app" \
    "$HOME/Applications/Lidless.app"
  do
    if [ -x "$candidate/Contents/MacOS/lidless-display-rescue" ]; then
      "$candidate/Contents/MacOS/lidless-display-rescue" "$@"
      return $?
    fi
  done

  echo "lidless-display-rescue was not found. It ships inside Lidless.app:" >&2
  echo "  <Lidless.app>/Contents/MacOS/lidless-display-rescue" >&2
  echo "Build it with ./build.sh, or run it directly if the app is elsewhere." >&2
  echo "With no display at all, from a shell on another machine:" >&2
  echo "  sudo killall -HUP WindowServer   # re-enumerates displays; logs you out" >&2
  return 1
}

status() {
  load_settings

  local caf lid power
  if is_caffeinated; then caf="yes"; else caf="no"; fi
  lid="$(lid_state)"

  # "unknown" gets its own headline rather than folding into ON/OFF/PARTIAL —
  # showing a confident-sounding state from an unreadable probe is exactly the
  # bug docs/ARCHITECTURE.md closes.
  if [ "$lid" = "unknown" ]; then
    echo "UNKNOWN — could not read the current lid setting"
  elif [ "$caf" = "yes" ] && [ "$lid" = "ignored" ]; then
    echo "ON"
  elif [ "$caf" = "no" ] && [ "$lid" = "normal" ] &&
       { [ -f "$LOWPOWER_FILE" ] || [ -f "$SCREENLOCK_FILE" ]; }; then
    echo "OFF — RESTORE PENDING"
  elif [ "$caf" = "no" ] && [ "$lid" = "normal" ]; then
    echo "OFF"
  else
    echo "PARTIAL"
  fi
  echo "caffeinate=$caf lid_state=$lid"

  # A pending shutdown, first, because it is the one line here with a deadline.
  # status() used to be blind to it: the file was read in exactly two places,
  # both inside cancel_pending_shutdown. Someone who got the 60-second warning
  # and ran `status` learned nothing, while the app showed a live countdown.
  if [ -f "$SHUTDOWN_PENDING_FILE" ]; then
    local pending_deadline pending_left
    pending_deadline="$(cat "$SHUTDOWN_PENDING_FILE" 2>/dev/null || true)"
    if is_plausible_epoch "$pending_deadline"; then
      pending_left=$(( pending_deadline - $(date +%s) ))
      if [ "$pending_left" -gt 0 ]; then
        echo "AUTOMATIC SHUTDOWN PENDING — about ${pending_left}s left. Cancel with '$(basename "$0") cancel-shutdown'."
      else
        echo "AUTOMATIC SHUTDOWN PENDING — the grace period has expired; the power-off is being requested now."
      fi
    else
      echo "AUTOMATIC SHUTDOWN PENDING — deadline unreadable. Cancel with '$(basename "$0") cancel-shutdown'."
    fi
  fi

  # How long this session has been up, and how long the hours limit leaves it.
  # The app has had a session clock since the beginning; the script had the same
  # timestamp file and never read it.
  if [ -f "$ENABLEDAT_FILE" ]; then
    local started_at session_seconds session_hours session_minutes
    started_at="$(cat "$ENABLEDAT_FILE" 2>/dev/null || true)"
    if is_plausible_epoch "$started_at"; then
      session_seconds=$(( $(date +%s) - started_at ))
      [ "$session_seconds" -lt 0 ] && session_seconds=0
      session_hours=$(( session_seconds / 3600 ))
      session_minutes=$(( (session_seconds % 3600) / 60 ))
      if [ "$SET_SHUTDOWN_AFTER_HOURS" -gt 0 ]; then
        local limit_left
        limit_left=$(( SET_SHUTDOWN_AFTER_HOURS * 3600 - session_seconds ))
        if [ "$limit_left" -gt 0 ]; then
          echo "session: ${session_hours}h ${session_minutes}m (shutdown limit in $(( limit_left / 3600 ))h $(( (limit_left % 3600) / 60 ))m)"
        else
          echo "session: ${session_hours}h ${session_minutes}m (past the ${SET_SHUTDOWN_AFTER_HOURS}h limit — the next watchdog tick powers this Mac off)"
        fi
      else
        echo "session: ${session_hours}h ${session_minutes}m"
      fi
    else
      echo "session: start time unreadable"
    fi
  fi

  # Is the built-in screen dark right now? The setting is printed further down,
  # but a setting is not a state, and this is the state a remote session cannot
  # see any other way.
  if [ -f "$DISPLAY_MARKER_FILE" ]; then
    local heartbeat_age
    heartbeat_age=""
    if [ -f "$DISPLAY_HEARTBEAT_FILE" ]; then
      heartbeat_age=$(( $(date +%s) - $(stat -f %m "$DISPLAY_HEARTBEAT_FILE" 2>/dev/null || echo 0) ))
    fi
    if [ -z "$heartbeat_age" ]; then
      echo "built-in panel: BLACKED OUT, and no heartbeat — nothing is managing it. Run '$(basename "$0") rescue-display'."
    elif [ "$heartbeat_age" -lt 0 ] || [ "$heartbeat_age" -ge "$DISPLAY_HEARTBEAT_STALE_AFTER" ]; then
      echo "built-in panel: BLACKED OUT, heartbeat ${heartbeat_age}s old — its owner looks hung. Run '$(basename "$0") rescue-display'."
    else
      echo "built-in panel: blacked out, heartbeat ${heartbeat_age}s old — a live Lidless is holding it"
    fi
  fi

  # Whether the one-time permission is in place. The app gives this a permanent
  # card; the script knew the path and never looked.
  if automatic_shutdown_helper_is_current; then
    echo "power permission: installed (helper v$AUTOMATIC_SHUTDOWN_HELPER_VERSION)"
  elif [ -e "$AUTOMATIC_SHUTDOWN_HELPER" ]; then
    echo "power permission: OUTDATED helper — re-run tools/install-auto-shutdown.sh"
  else
    echo "power permission: not installed — unattended shutdown cannot work; run tools/install-auto-shutdown.sh"
  fi
  power="$(power_source)"
  case "$power" in
    battery) echo "power: BATTERY — lid stays ignored, so this drains" ;;
    ac)      echo "power: AC" ;;
    *)       echo "power: unknown — could not read the current power source" ;;
  esac
  # Tri-state display, not lowpower_or_zero's fabricated "0" — an unreadable
  # probe used to look identical to a confirmed-off value here. Same for
  # battery presence: `battery_presence`, not the plain boolean `has_battery`,
  # so an ambiguous read shows "unknown" rather than mislabeling the machine
  # a desktop. review round 3.
  local lp_ac_display lp_presence_display lp_battery_display
  lp_ac_display=$(read_lowpower_value "AC Power")
  lp_presence_display=$(battery_presence)
  case "$lp_presence_display" in
    yes) lp_battery_display=$(read_lowpower_value "Battery Power") ;;
    *) lp_battery_display="unknown" ;;
  esac
  case "$lp_presence_display" in
    yes) echo "low power mode: ac=$lp_ac_display battery=$lp_battery_display" ;;
    no)  echo "low power mode: ac=$lp_ac_display (desktop — no battery)" ;;
    *)   echo "low power mode: ac=$lp_ac_display battery=unknown (could not confirm whether this Mac has a battery)" ;;
  esac
  if ! has_lid; then
    echo "lid: none — this is a desktop Mac, so lid settings do nothing here"
  fi
  echo "screen lock delay: $(read_screenlock)"
  if [ -f "$SCREENLOCK_FILE" ]; then
    echo "original screen lock saved: $(cat "$SCREENLOCK_FILE")"
  fi
  if [ -f "$LOWPOWER_FILE" ]; then
    echo "original low power saved: $(cat "$LOWPOWER_FILE") (ac:battery)"
  fi

  # Which settings are in force, and where they came from. The app and the
  # script used to disagree silently: ticking a box in the app changed nothing
  # about what the script did.
  echo
  echo "settings from: $SETTINGS_SOURCE"
  echo "  keep awake on battery:  $(yes_no "$SET_KEEP_AWAKE_ON_BATTERY")"
  echo "  low power while active: $(yes_no "$SET_LOW_POWER")"
  echo "  relax screen lock:      $(yes_no "$SET_SCREENLOCK") ($(screenlock_target "$SET_SCREENLOCK_DELAY"))"
  echo "  stop all caffeinate:    $(yes_no "$SET_STOP_ALL_CAFFEINATE")"
  echo "  auto-shutdown after:    $(never_or "$SET_SHUTDOWN_AFTER_HOURS" "h")"
  echo "  auto-shutdown below:    $(never_or "$SET_SHUTDOWN_BELOW_BATTERY_PERCENT" "%")"
  echo "  panel blackout:         $(yes_no "$SET_BLACKOUT_BUILTIN_DISPLAY") (app only)"
  echo "  panel blackout mode:    $SET_PANEL_MODE (app only)"

  # SleepDisabled is written to /Library/Preferences/com.apple.PowerManagement.plist
  # and survives reboots. Left behind by a crash it silently keeps the Mac awake
  # forever, so say so loudly rather than showing a tidy "PARTIAL".
  if [ "$lid" = "ignored" ] && [ "$caf" = "no" ]; then
    echo
    echo "WARNING: this Mac ignores lid close but nothing is managing it."
    echo "         That setting persists across reboots. Run '$(basename "$0") off'"
    echo "         unless you deliberately want it kept."
  fi
}

cancel_pending_shutdown() {
  if [ ! -f "$SHUTDOWN_PENDING_FILE" ]; then
    # Said out loud, not just returned. This is the command people run under
    # time pressure, seconds after a "the Mac will shut down" notification, and
    # it used to print nothing at all — an empty terminal that looks exactly
    # like a command that worked, and exactly like one that was mistyped.
    echo "No automatic shutdown is pending; nothing to cancel."
    return 1
  fi
  printf 'cancel\n' > "$SHUTDOWN_CANCEL_FILE"
  rm -f "$SHUTDOWN_PENDING_FILE"
  echo "Pending automatic shutdown cancellation requested."
}

# ---------------------------------------------------------------------------
# set — write a shared setting, refusing values the app cannot display
# ---------------------------------------------------------------------------
#
# README used to tell people to `defaults write` these by hand, and docs/ARCHITECTURE.md
# records where that leads: the app's Pickers tag a fixed set of values, so a
# hand-written `screenLockDelay 60` is silently accepted by `defaults` and then
# renders as a Picker with nothing selected. The allowed sets below are the
# Pickers' own tag sets (Sources/main.swift), which is the whole point — this
# command cannot produce a value the app cannot show.

# One list, used by the no-argument listing and the unknown-key message. The
# validation tables in validate_setting are the authority on what each key
# accepts; this is only the enumeration order.
LIDLESS_SETTING_KEYS="keepAwakeOnBattery lowPowerWhileActive relaxScreenLock screenLockDelay stopAllCaffeinate automaticShutdownAfterHoursV1 automaticShutdownBelowBatteryPercentV1 blackoutBuiltinDisplayV1 panelModeV1"

# Pure. Prints "<defaults-type> <normalized-value>" for a key/value the app can
# display; returns 1 for a value outside the key's set, 2 for an unknown key.
# Booleans accept the spellings people actually type; everything is normalized
# to what `defaults read` will print back, so status() and the app agree.
validate_setting() {
  local key="$1" value="$2"
  case "$key" in
    keepAwakeOnBattery|lowPowerWhileActive|relaxScreenLock|stopAllCaffeinate|blackoutBuiltinDisplayV1)
      case "$value" in
        1|true|on|yes) echo "-bool true" ;;
        0|false|off|no) echo "-bool false" ;;
        *) return 1 ;;
      esac ;;
    screenLockDelay)
      case "$value" in
        0|300|900|3600) echo "-int $value" ;;
        *) return 1 ;;
      esac ;;
    automaticShutdownAfterHoursV1)
      case "$value" in
        0|1|2|4|8) echo "-int $value" ;;
        *) return 1 ;;
      esac ;;
    automaticShutdownBelowBatteryPercentV1)
      case "$value" in
        0|10|20|30) echo "-int $value" ;;
        *) return 1 ;;
      esac ;;
    panelModeV1)
      # panel_mode_value() reads anything unknown as "virtual", so an arbitrary
      # string would not break the app — but it would sit in the domain as a
      # value the segmented control cannot show, which is the same Picker
      # failure as the numbers above.
      case "$value" in
        dim|virtual) echo "-string $value" ;;
        *) return 1 ;;
      esac ;;
    *) return 2 ;;
  esac
}

# Pure. The human-readable half of the same table, for error messages and the
# listing. `0` is spelled with its meaning where 0 means "never" rather than
# "off", because that difference has already confused one measured session.
setting_allowed_values() {
  case "$1" in
    keepAwakeOnBattery|lowPowerWhileActive|relaxScreenLock|stopAllCaffeinate|blackoutBuiltinDisplayV1)
      echo "0|1 (also true/false, on/off, yes/no)" ;;
    screenLockDelay) echo "0 (never), 300, 900, 3600" ;;
    automaticShutdownAfterHoursV1) echo "0 (never), 1, 2, 4, 8" ;;
    automaticShutdownBelowBatteryPercentV1) echo "0 (never), 10, 20, 30" ;;
    panelModeV1) echo "virtual, dim" ;;
    *) return 1 ;;
  esac
}

list_settings() {
  local key current
  echo "Shared settings in the $DEFAULTS_DOMAIN domain."
  echo "Set one with: $(basename "$0") set <key> <value>"
  echo
  for key in $LIDLESS_SETTING_KEYS; do
    current="$(read_default_raw "$key")"
    if [ -z "$current" ]; then
      current="(unset — the fallback in this script applies)"
    fi
    printf '  %-42s %s\n' "$key" "$current"
    printf '  %-42s allowed: %s\n' "" "$(setting_allowed_values "$key")"
  done
}

set_setting() {
  local key="${1:-}" value="${2:-}" spec rc
  if [ -z "$key" ]; then
    list_settings
    return 0
  fi
  if [ -z "$value" ]; then
    echo "Usage: $(basename "$0") set <key> <value>   (or bare 'set' to list)" >&2
    return 1
  fi
  rc=0
  spec="$(validate_setting "$key" "$value")" || rc=$?
  if [ "$rc" = "2" ]; then
    echo "Unknown setting '$key'. Keys: $LIDLESS_SETTING_KEYS" >&2
    return 1
  fi
  if [ "$rc" != "0" ]; then
    echo "Invalid value '$value' for $key. Allowed: $(setting_allowed_values "$key")" >&2
    echo "These are the app's own Picker choices — any other value would show as an empty selection there." >&2
    return 1
  fi
  local type normalized
  read -r type normalized <<<"$spec"
  if ! defaults write "$DEFAULTS_DOMAIN" "$key" "$type" "$normalized"; then
    echo "defaults write failed; the setting was not changed." >&2
    return 1
  fi
  echo "$key = $normalized"
  # @AppStorage observes the domain through cfprefsd, so a running app updates
  # without a restart — stated so nobody quits the app "to make it take".
  echo "A running Lidless app picks this up immediately; no restart needed."
}

# Sourcing this file defines the functions without running anything — that is
# how tests/run.sh gets at the parsers. Executing it still dispatches normally.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    on) with_lock on ;;
    off) with_lock off ;;
    # Outside with_lock deliberately: it writes preferences, not session state.
    # The lock serialises enable/disable teardown; a setting write races nothing
    # that the on()/off() critical sections read mid-flight — both load settings
    # once, up front.
    set) shift; set_setting "$@" ;;
    cancel-shutdown) cancel_pending_shutdown ;;
    # Deliberately outside with_lock: that lock serialises enable/disable against
    # the app, and this has to work when the app is hung holding it. Every action
    # it takes only makes a display visible, so it cannot make anything worse by
    # racing.
    rescue-display) shift; rescue_display "$@" ;;
    status) status ;;
    *) usage ;;
  esac
fi
