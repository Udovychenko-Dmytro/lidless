#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Dmytro Udovychenko
#
# The watchdog. Run periodically by io.github.lidless.check.plist.
#
# `pmset disablesleep` is stored in /Library/Preferences/com.apple.PowerManagement.plist
# and survives reboots, so a forgotten session is silent and permanent. Two
# things happen here:
#
#   1. If an automatic-shutdown limit is exceeded, the Mac is powered off.
#      This is the path that still works after the app itself has quit.
#   2. Otherwise, if the lid setting is on with nothing managing it, it warns.
#
# Powering off uses the root-owned, argument-free helper installed from the
# README. With no terminal there is nobody to type a password, so lidless.sh
# uses `sudo -n`: silent when installed, and a clean failure plus notification
# otherwise. No password is ever read, stored or forwarded by this code.
#
# Install: see "enforce automatic shutdown after quitting" in the README.
#
set -euo pipefail

# --- locate lidless.sh -------------------------------------------------
#
# All the real logic lives there, so the watchdog cannot drift out of step with
# the tool it is watching. Set LIDLESS_SH if it lives somewhere unusual.

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*"
}

notify() {
  osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true
}

find_lidless() {
  local here candidate
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for candidate in "${LIDLESS_SH:-}" "$here/../lidless.sh" \
                   "$here/lidless.sh" "$HOME/bin/lidless.sh"; do
    if [ -n "$candidate" ] && [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

if ! LIB="$(find_lidless)"; then
  log "ERROR: cannot find lidless.sh — set LIDLESS_SH in the LaunchAgent plist"
  notify "Lidless watchdog broken" \
         "It cannot find lidless.sh, so it is guarding nothing. See the README."
  exit 1
fi

# shellcheck source=../lidless.sh
# Checked, not bare — `find_lidless` only confirms the file exists, not that
# sourcing it succeeds (a syntax error or unreadable permissions would still
# fail here); under this script's `set -e`, a bare failure would kill the
# unattended watchdog with zero notification, silently disabling the whole
# safety net. GPT critic-loop round 6.
if ! source "$LIB"; then
  log "ERROR: failed to load $LIB — guarding nothing this run"
  notify "Lidless watchdog broken" \
         "It could not load lidless.sh, so it is guarding nothing. See the README."
  exit 1
fi

# --- decide ----------------------------------------------------------------

load_settings

LID_STATE="$(lid_state)"
if [ "$LID_STATE" = "normal" ]; then
  # Normal state. Say nothing: this runs every few minutes, and a quiet log is
  # a readable one.
  exit 0
elif [ "$LID_STATE" = "unknown" ]; then
  # A single ambiguous sample is not enough to force an off nobody asked for,
  # but it must not cancel an already-due limit for a known Lidless session.
  # PID/timestamp files are explicit session evidence; without either, log and
  # stop. With evidence, continue to the normal deadline calculation below —
  # off() already treats unknown as fail-safe and re-verifies the restore.
  log "probe unreadable: could not tell whether the lid setting is on"
  if [ ! -f "$PID_FILE" ] && [ ! -f "$ENABLEDAT_FILE" ]; then
    exit 0
  fi
fi

STARTED=""
if [ -f "$ENABLEDAT_FILE" ]; then
  STARTED="$(cat "$ENABLEDAT_FILE" 2>/dev/null || true)"
fi
if ! is_plausible_epoch "$STARTED" && [ -f "$PID_FILE" ]; then
  # Either enabled before the timestamp file existed, or the file exists but
  # is empty/corrupted (e.g. a crash during the non-atomic `date +%s >
  # "$ENABLEDAT_FILE"` write in on()) — either way, the pid file's mtime (set
  # at the same moment `on()` started the session) is a plausible fallback.
  # Without this, an empty/malformed-but-present file used to be trusted as
  # "no plausible epoch, skip the hours guard" forever — silently and
  # permanently disabling the auto-off hours protection this tool exists to
  # provide, since a present-but-corrupt file is never replaced by on()
  # either (it only writes when the file is entirely absent). See
  # docs/plans/done/SAFETY_FIXES_PLAN.md — GPT critic-loop round 10.
  STARTED="$(stat -f %m "$PID_FILE" 2>/dev/null || true)"
  if is_plausible_epoch "$STARTED"; then
    if echo "$STARTED" > "$ENABLEDAT_FILE" 2>/dev/null; then
      log "repaired an empty/malformed .lidless_enabled_at using the pid file's timestamp"
    else
      log "repaired an empty/malformed .lidless_enabled_at in memory (using the pid file's timestamp), but could not persist it"
    fi
  fi
fi

# A timestamp more than ENABLED_AT_FUTURE_TOLERANCE in the future is treated
# as corrupted, not ordinary clock skew — repaired to now (restarting the
# auto-off window) rather than left to silently suppress the hours guard
# forever. Mirrors Sources/main.swift's ensureEnabledAt. See
# docs/plans/done/SAFETY_FIXES_PLAN.md Phase 7.
if is_plausible_epoch "$STARTED"; then
  read -r RESOLVED_STARTED RESOLVED_STATUS <<<"$(resolve_started_at "$STARTED" "$(date +%s)")"
  if [ "$RESOLVED_STATUS" = "repaired" ]; then
    # Checked, not bare — a failed write here must not abort this run before
    # it even reaches the auto-off decision below; $STARTED is already
    # corrected in memory regardless of whether the repair persists to disk.
    if echo "$RESOLVED_STARTED" > "$ENABLEDAT_FILE" 2>/dev/null; then
      log "repaired a future .lidless_enabled_at timestamp — restarting the auto-off window"
    else
      log "repaired a future .lidless_enabled_at timestamp in memory, but could not persist it"
    fi
  fi
  STARTED="$RESOLVED_STARTED"
fi

# One snapshot per decision, not two separate `pmset -g ps` calls — a
# plug/unplug transition between two reads could combine "battery" from the
# first with an AC percentage from the second and trigger an incorrect
# auto-off. See docs/plans/done/SAFETY_FIXES_PLAN.md — GPT critic-loop round 4.
#
# A function because the decision is now taken twice: once to arm the grace
# period, and once at the end of it (see "re-evaluate" below). Each call takes
# its own single snapshot; what must not be mixed is one reading with another
# reading of the same pass.
# $1 = session start epoch.
current_auto_off_reason() {
  local ps_output power_source on_battery percent
  ps_output="$(pmset -g ps 2>/dev/null)" || ps_output=""
  power_source="$(power_source_from "$ps_output")"
  on_battery=0
  [ "$power_source" = "battery" ] && on_battery=1
  percent=""
  [ "$power_source" = "unknown" ] || percent="$(printf '%s' "$ps_output" | parse_battery_percent || true)"
  auto_off_reason "$1" "$(date +%s)" "$on_battery" "$percent"
}

REASON="$(current_auto_off_reason "$STARTED")"

# --- act -------------------------------------------------------------------

if [ -n "$REASON" ]; then
  log "automatic shutdown triggered: $REASON"
  rm -f "$SHUTDOWN_CANCEL_FILE"
  printf '%s\n' "$(( $(date +%s) + AUTOMATIC_SHUTDOWN_GRACE_SECONDS ))" > "$SHUTDOWN_PENDING_FILE"
  notify "Mac will shut down in ${AUTOMATIC_SHUTDOWN_GRACE_SECONDS}s" \
         "Lidless limit reached ($REASON). Open Lidless or run 'lidless.sh cancel-shutdown' to cancel."
  if [ "$AUTOMATIC_SHUTDOWN_GRACE_SECONDS" -gt 0 ]; then
    sleep "$AUTOMATIC_SHUTDOWN_GRACE_SECONDS"
  fi
  if [ -f "$SHUTDOWN_CANCEL_FILE" ]; then
    rm -f "$SHUTDOWN_CANCEL_FILE" "$SHUTDOWN_PENDING_FILE"
    log "automatic shutdown cancelled during grace period"
    notify "Automatic shutdown cancelled" "Lidless remains active."
    exit 0
  fi
  # Re-evaluate before acting. The grace period exists so a human can react,
  # and the obvious reaction to "battery at 12%" is to plug the charger in —
  # which used to change nothing, because the only thing consulted after the
  # sleep was the cancel file. The session can also end during the grace
  # (`lidless.sh off`), so the start timestamp is re-read rather than reused.
  # Mirrors the app's SystemProbe.automaticShutdownStillWarranted.
  STARTED_NOW=""
  if [ -f "$ENABLEDAT_FILE" ]; then
    STARTED_NOW="$(cat "$ENABLEDAT_FILE" 2>/dev/null || true)"
  fi
  REASON_NOW="$(current_auto_off_reason "$STARTED_NOW")"
  if [ -z "$REASON_NOW" ]; then
    rm -f "$SHUTDOWN_PENDING_FILE"
    log "automatic shutdown abandoned: the condition no longer holds (was: $REASON)"
    notify "Automatic shutdown abandoned" \
           "The condition that triggered it no longer applies. Lidless remains active."
    exit 0
  fi

  rm -f "$SHUTDOWN_PENDING_FILE"
  # set -e is active in this script — capture the exit code via && / || rather
  # than a bare command followed by `SHUTDOWN_RC=$?`, which would abort the script on
  # any nonzero before the case below ever runs.
  with_lock automatic_shutdown && SHUTDOWN_RC=0 || SHUTDOWN_RC=$?
  case "$SHUTDOWN_RC" in
    0)
      log "automatic shutdown requested"
      if [ -n "$AUTOMATIC_SHUTDOWN_WARNING" ]; then
        notify "Lidless restore incomplete" "$AUTOMATIC_SHUTDOWN_WARNING"
      fi
      ;;
    75)
      # EX_TEMPFAIL from lockf, propagated by with_lock — a concurrent
      # CLI/app operation holds the lock right now. Transient, not a hard
      # failure: the next watchdog tick (every 300s) retries on its own.
      log "automatic shutdown deferred: another Lidless process is currently enabling/disabling"
      ;;
    78)
      log "automatic shutdown cancelled: screen lock needs an interactive restore"
      notify "Automatic shutdown cancelled" \
             "Open Lidless and press Disable to restore the screen-lock setting first."
      ;;
    *)
      log "automatic shutdown FAILED: helper missing, outdated, denied, or shutdown request rejected"
      notify "Automatic shutdown failed" \
             "The Mac was not powered off ($REASON). Run tools/install-auto-shutdown.sh."
      ;;
  esac
  exit 0
fi

# Unknown reached this point only with session evidence, but no configured
# limit is due yet. Do not reinterpret that ambiguity as an orphaned confirmed
# lid setting; the next watchdog tick samples it again.
if [ "$LID_STATE" = "unknown" ]; then
  exit 0
fi

if ! is_caffeinated; then
  # Lid ignored, nothing managing it. Deliberately only a warning: the setting
  # may have been made deliberately, by this tool or by hand, and silently
  # undoing someone else's choice is worse than telling them about it.
  log "warned: SleepDisabled=1 with no caffeinate"
  notify "Lidless left on" \
         "This Mac ignores lid close and nothing is managing it. Open Lidless and press Disable."
fi

exit 0
