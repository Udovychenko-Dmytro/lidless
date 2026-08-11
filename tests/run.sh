#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Dmytro Udovychenko
#
# Behavioural tests for lidless.sh.
#
# Every real bug this tool has had was in parsing command output or in trusting
# an exit code, so that is what these cover. The parsers are fed fixture files
# captured from real Macs; the probes are run against fake `pmset`, `ioreg`,
# `ps` and `sysadminctl` in tests/bin, which is early on PATH.
#
# Nothing here touches the real system. HOME is redirected into a temp directory
# before lidless.sh is sourced, because that is when the state-file paths are
# computed — the machine running these tests may have Lidless genuinely on,
# and a test must never disturb it.
#
# Run: ./tests/run.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/tests/fixtures"

# Checked explicitly, not just trusted — this file runs under `set -uo
# pipefail`, not `-e`, so a failed `mktemp` would otherwise leave $TMP empty
# and every subsequent "$TMP/..." path would silently resolve to a root-level
# path ("/home", "/orphan-install", ...) instead of stopping the suite. review
#  round 5.
TMP="$(mktemp -d "${TMPDIR:-/tmp}/lidless-tests.XXXXXX")" || TMP=""
if [ -z "$TMP" ]; then
  echo "Could not create the isolated test directory." >&2
  exit 1
fi
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
mkdir -p "$HOME"
export PATH="$ROOT/tests/bin:$PATH"

# `kill` is a shell builtin, unlike pmset/sudo/ps/etc — PATH alone would never
# reach tests/bin/kill for a bare `kill "$pid"` call (xargs kill already
# bypasses the builtin on its own, since xargs execs argv directly). Disable
# the builtin so stop_our_caffeinate's kill calls hit the fake instead of a
# real, possibly-unrelated process. `enable` is a long-standing builtin,
# available since well before bash 3.2.
enable -n kill

# shellcheck source=../lidless.sh
source "$ROOT/lidless.sh"

# lidless.sh turns on errexit; the assertions below report their own
# failures and must not abort the run. pipefail stays ON deliberately — it is
# the precondition for the `| grep -q` bug, so a suite that switched it off
# would prove nothing about the probes.
set +e
set -o pipefail

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

PASS=0
FAIL=0

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; R=$'\033[31m'; D=$'\033[2m'; N=$'\033[0m'
else B=""; G=""; R=""; D=""; N=""; fi

section() { printf '\n%s%s%s\n' "$B" "$1" "$N"; }
ok()      { PASS=$((PASS + 1)); printf '  %sok%s   %s\n' "$G" "$N" "$1"; }
bad()     { FAIL=$((FAIL + 1)); printf '  %sFAIL%s %s\n' "$R" "$N" "$1"; }

# is <name> <expected> <actual>
is() {
  if [ "$2" = "$3" ]; then
    ok "$1"
  else
    bad "$1"
    printf '       %sexpected:%s %s\n       %sactual:  %s %s\n' "$D" "$N" "[$2]" "$D" "$N" "[$3]"
  fi
}

# succeeds <name> <command...>
succeeds() {
  local name="$1"; shift
  if "$@"; then ok "$name"; else bad "$name (expected exit 0, got $?)"; fi
}

# fails <name> <command...>
fails() {
  local name="$1"; shift
  if "$@"; then bad "$name (expected non-zero, got 0)"; else ok "$name"; fi
}

# contains <needle> <haystack>
contains() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# mentions <name> <needle> <haystack>
mentions() {
  if contains "$2" "$3"; then
    ok "$1"
  else
    bad "$1"
    printf '       %slooked for:%s %s\n       %sin:%s %s\n' "$D" "$N" "[$2]" "$D" "$N" "[$3]"
  fi
}

# lacks <name> <needle> <haystack> — asserts the needle is NOT present
lacks() {
  if contains "$2" "$3"; then
    bad "$1"
    printf '       %sdid not expect:%s %s\n       %sin:%s %s\n' "$D" "$N" "[$2]" "$D" "$N" "[$3]"
  else
    ok "$1"
  fi
}

# ---------------------------------------------------------------------------
section "parse_pmset_custom — laptop"
# ---------------------------------------------------------------------------

MACBOOK="$FIXTURES/pmset-custom-macbook.txt"

is "AC lowpowermode"          "0"  "$(parse_pmset_custom 'AC Power' lowpowermode < "$MACBOOK")"
is "battery lowpowermode"     "1"  "$(parse_pmset_custom 'Battery Power' lowpowermode < "$MACBOOK")"
is "AC displaysleep"          "10" "$(parse_pmset_custom 'AC Power' displaysleep < "$MACBOOK")"
is "battery displaysleep"     "5"  "$(parse_pmset_custom 'Battery Power' displaysleep < "$MACBOOK")"
is "key absent from section"  ""   "$(parse_pmset_custom 'AC Power' lessbright < "$MACBOOK")"
is "key absent everywhere"    ""   "$(parse_pmset_custom 'AC Power' nosuchkey < "$MACBOOK")"

# --- a stray extra token must not fall through to whatever $2 happens to be -
# Swift's lowPowerValue requires exactly two fields; this used to accept a
# third token silently, disagreeing with Swift on the same malformed line.
# review round 5.
is "extra trailing token is unreadable, not the value in field 2" "" \
   "$(printf "AC Power:\n lowpowermode 1 garbage\n" | parse_pmset_custom 'AC Power' lowpowermode)"
is "extra leading-side token (still 3 fields) is unreadable too" "" \
   "$(printf "AC Power:\n lowpowermode garbage 1\n" | parse_pmset_custom 'AC Power' lowpowermode)"

# ---------------------------------------------------------------------------
section "parse_pmset_custom — desktop (regression: no Battery Power section)"
# ---------------------------------------------------------------------------

# A Mac mini / iMac / Mac Studio prints only an "AC Power:" section. An earlier
# implementation used the awk range /^Battery Power/,/^AC Power/ and returned
# empty on these machines even for AC values.
MACMINI="$FIXTURES/pmset-custom-macmini.txt"

is "desktop AC lowpowermode readable" "0" "$(parse_pmset_custom 'AC Power' lowpowermode < "$MACMINI")"
is "desktop AC displaysleep readable" "10" "$(parse_pmset_custom 'AC Power' displaysleep < "$MACMINI")"
is "desktop battery section is empty" ""  "$(parse_pmset_custom 'Battery Power' lowpowermode < "$MACMINI")"

# lowpower_or_zero is what keeps the saved "ac:battery" state well-formed when
# one of the two sources does not exist.
is "empty battery reads as 0" "0" "$(lowpower_or_zero "$(parse_pmset_custom 'Battery Power' lowpowermode < "$MACMINI")")"
is "present value passes through" "1" "$(lowpower_or_zero "$(parse_pmset_custom 'Battery Power' lowpowermode < "$MACBOOK")")"

# ---------------------------------------------------------------------------
section "parse_pmset_custom — section order is not assumed"
# ---------------------------------------------------------------------------

ACFIRST="$FIXTURES/pmset-custom-ac-first.txt"

is "AC value when AC comes first"      "0" "$(parse_pmset_custom 'AC Power' lowpowermode < "$ACFIRST")"
is "battery value when AC comes first" "1" "$(parse_pmset_custom 'Battery Power' lowpowermode < "$ACFIRST")"

# ---------------------------------------------------------------------------
section "parse_lowpower_field — both names for the same setting"
# ---------------------------------------------------------------------------

# macOS 15 prints `powermode`, macOS 26 prints `lowpowermode`. Reading only the
# latter made every Low Power Mode reading on 15 "unknown": the tile said so,
# and Enable refused to save or apply the setting at all.
SEQUOIA="$FIXTURES/pmset-custom-sequoia.txt"

is "macOS 15 AC powermode"       "0" "$(parse_lowpower_field 'AC Power' < "$SEQUOIA")"
is "macOS 15 battery powermode"  "1" "$(parse_lowpower_field 'Battery Power' < "$SEQUOIA")"
is "macOS 26 AC lowpowermode"    "0" "$(parse_lowpower_field 'AC Power' < "$MACBOOK")"
is "macOS 26 battery lowpowermode" "1" "$(parse_lowpower_field 'Battery Power' < "$MACBOOK")"
is "desktop has no battery section" "" "$(parse_lowpower_field 'Battery Power' < "$MACMINI")"

# High Power Mode (powermode 2) is not "off": the restore only writes
# lowpowermode 0/1, so it must read as unknown rather than demote the Mac.
is "powermode 2 is not a 0|1 reading" "2" \
   "$(printf "AC Power:\n powermode            2\n" | parse_lowpower_field 'AC Power')"

# The first row carrying either name decides, malformed included — falling back
# to the other name would turn unreadable output into a confirmed reading, and
# Swift's lowPowerValue (one pass over both names) would disagree.
is "malformed first row does not fall through to the other name" "" \
   "$(printf "AC Power:\n lowpowermode 1 garbage\n powermode 0\n" | parse_lowpower_field 'AC Power')"

# ---------------------------------------------------------------------------
section "parse_screenlock"
# ---------------------------------------------------------------------------

is "delay in seconds"    "900"       "$(parse_screenlock < "$FIXTURES/sysadminctl-900.txt")"
is "lock disabled"       "off"       "$(parse_screenlock < "$FIXTURES/sysadminctl-off.txt")"
is "immediate"           "immediate" "$(parse_screenlock < "$FIXTURES/sysadminctl-immediate.txt")"
is "refusal is not a value" "unknown" "$(parse_screenlock < "$FIXTURES/sysadminctl-password-required.txt")"
is "empty output"        "unknown"   "$(parse_screenlock < "$FIXTURES/sysadminctl-empty.txt")"

# ---------------------------------------------------------------------------
section "validate_saved_screenlock"
# ---------------------------------------------------------------------------

is "off passes through"        "off"       "$(validate_saved_screenlock off)"
is "immediate passes through"  "immediate" "$(validate_saved_screenlock immediate)"
is "seconds pass through"      "900"       "$(validate_saved_screenlock 900)"
is "zero is valid"             "0"         "$(validate_saved_screenlock 0)"
# A leading zero must be canonicalized away, matching Swift's
# Int("0900") == 900 (then re-stringified) — review round 9 caught
# that an earlier version of this function passed "0900" through unchanged,
# which could later fail set_screenlock's own re-verification (comparing
# against real sysadminctl output, which is always canonical) even after the
# value was genuinely, successfully applied.
is "leading zero is canonicalized" "900" "$(validate_saved_screenlock 0900)"
is "reject a value that is neither off/immediate nor a number" "" \
   "$(validate_saved_screenlock garbage)"
is "reject shell syntax" "" "$(validate_saved_screenlock '900; /usr/bin/false')"
is "reject a value long enough to overflow" "" \
   "$(validate_saved_screenlock 99999999999999999999)"

# ---------------------------------------------------------------------------
section "validate_saved_lowpower"
# ---------------------------------------------------------------------------
#
# Its sibling above has nine assertions; this had none — it appeared in this
# file only inside a comment. Its own comment names the regression it exists to
# stop: a colonless "0"/"1" that `%%`/`##` would silently accept as
# ac==battery, feeding whatever the file held to `pmset -c/-b lowpowermode`.

is "0:0 splits into two values"  "0 0" "$(validate_saved_lowpower 0:0)"
is "0:1 splits into two values"  "0 1" "$(validate_saved_lowpower 0:1)"
is "1:0 splits into two values"  "1 0" "$(validate_saved_lowpower 1:0)"
is "1:1 splits into two values"  "1 1" "$(validate_saved_lowpower 1:1)"
# The named regression. Both `${saved%%:*}` and `${saved##*:}` return the whole
# string when there is no colon, so this used to read as ac==battery==0.
is "a colonless 0 is rejected, not read as ac==battery" "" \
   "$(validate_saved_lowpower 0)"
is "a colonless 1 is rejected too" "" "$(validate_saved_lowpower 1)"
fails "and it reports the rejection to its caller" eval 'validate_saved_lowpower 1 >/dev/null'
is "an empty value is rejected" "" "$(validate_saved_lowpower '')"
is "a lone colon is rejected" "" "$(validate_saved_lowpower ':')"
is "values outside 0/1 are rejected" "" "$(validate_saved_lowpower 2:0)"
is "three fields are rejected" "" "$(validate_saved_lowpower 0:1:0)"
is "whitespace is not trimmed into validity" "" "$(validate_saved_lowpower ' 0:1')"
# It feeds a privileged command; a value that survives validation is a value
# that reaches `sudo pmset`.
is "shell syntax is rejected" "" "$(validate_saved_lowpower '0:1; /usr/bin/false')"
# Output suppressed: `succeeds` runs the function for its exit code, and its
# stdout would otherwise land in the middle of the results.
succeeds "a valid value reports success" eval 'validate_saved_lowpower 1:0 >/dev/null'

# ---------------------------------------------------------------------------
section "battery_presence: the three-rung cross-check ladder"
# ---------------------------------------------------------------------------
#
# No rung had an assertion. Its own comment says why that matters: treating a
# failed probe as "no battery" "used to skip that restore silently, then delete
# the saved value anyway, losing the battery-side setting permanently".
# Two coordinated pmset shims per case — `-g custom` for the first read and
# `-g batt` for the cross-check.

BP_GARBAGE="$TMP/pmset-custom-garbage.txt"
printf 'some unrelated output\n' > "$BP_GARBAGE"

export FAKE_PMSET_CUSTOM="$FIXTURES/pmset-custom-macbook.txt"
is "a Battery Power section is a battery, no cross-check needed" "yes" "$(battery_presence)"

export FAKE_PMSET_CUSTOM="$FIXTURES/pmset-custom-macmini.txt"
export FAKE_PMSET_PS="$FIXTURES/pmset-ps-desktop.txt"
is "AC-only, and the cross-check agrees there is no battery" "no" "$(battery_presence)"

# The rung that matters: the two probes disagree. "unknown" is the honest
# answer, and "no" is the one that silently loses the battery-side setting.
export FAKE_PMSET_PS="$FIXTURES/pmset-ps-battery.txt"
is "AC-only but the cross-check finds a real battery: unknown, not no" "unknown" \
   "$(battery_presence)"

export FAKE_PMSET_FAIL_PS=1
is "AC-only and the cross-check cannot read at all: unknown" "unknown" "$(battery_presence)"
unset FAKE_PMSET_FAIL_PS

export FAKE_PMSET_CUSTOM="$BP_GARBAGE"
is "output with neither section is unknown, whatever the exit status" "unknown" \
   "$(battery_presence)"

export FAKE_PMSET_FAIL=1
is "a pmset that fails outright is unknown" "unknown" "$(battery_presence)"
unset FAKE_PMSET_FAIL

unset FAKE_PMSET_CUSTOM FAKE_PMSET_PS

# ---------------------------------------------------------------------------
section "power_source_from: one canonical line, or nothing"
# ---------------------------------------------------------------------------
#
# The `matches -eq 1` rule exists to reject output that claims both sources, or
# claims one twice — and nothing exercised it. A contradiction must read as
# "unknown", never as whichever line happened to be last.

is "a single battery line reads as battery" "battery" \
   "$(power_source_from "Now drawing from 'Battery Power'")"
is "a single AC line reads as ac" "ac" \
   "$(power_source_from "Now drawing from 'AC Power'")"
is "surrounding noise does not matter" "battery" \
   "$(power_source_from "$(printf 'header\nNow drawing from '"'"'Battery Power'"'"'\n -InternalBattery-0 18%%')")"
is "two contradictory lines are unknown, not the last one seen" "unknown" \
   "$(power_source_from "$(printf "Now drawing from 'AC Power'\nNow drawing from 'Battery Power'")")"
is "the same line twice is unknown too" "unknown" \
   "$(power_source_from "$(printf "Now drawing from 'AC Power'\nNow drawing from 'AC Power'")")"
is "no canonical line at all is unknown" "unknown" "$(power_source_from "some other output")"
is "empty output is unknown" "unknown" "$(power_source_from "")"
# Anchored on the whole line, so a diagnostic that quotes the phrase cannot
# answer for the real one.
is "the phrase quoted inside another line does not count" "unknown" \
   "$(power_source_from "warning: expected \"Now drawing from 'AC Power'\" here")"

# ---------------------------------------------------------------------------
section "parse_sleep_disabled (tri-state: ignored | normal | unknown)"
# ---------------------------------------------------------------------------
#
# "unknown" must never fold into "normal" — that fold is exactly the fail-open
# bug docs/ARCHITECTURE.md closes: a probe that could not
# be read used to look identical to a probe that confirmed the lid was fine.

# "key legitimately absent" is confirmed by Apple's own open-source pmset.c,
# show_system_power_settings() — it only prints the SleepDisabled line once
# the key exists in the settings dictionary, i.e. once it has actually been
# set. (pmset-g-sleepdisabled-off.txt is a SYNTHETIC fixture per
# tests/fixtures/README.md — it illustrates the confirmed behavior, it does
# not itself prove it.)
is "lid ignored"                  "ignored" "$(parse_sleep_disabled < "$FIXTURES/pmset-g-sleepdisabled-on.txt")"
is "lid normal (key legitimately absent — real pmset omits it at 0)" "normal" \
   "$(parse_sleep_disabled < "$FIXTURES/pmset-g-sleepdisabled-off.txt")"
is "key missing from unrelated output is also normal" "normal" \
   "$(parse_sleep_disabled < "$FIXTURES/pmset-custom-macbook.txt")"
is "empty input is normal (a pure parser has no failure signal of its own — that is lid_state's job)" \
   "normal" "$(printf '' | parse_sleep_disabled)"
is "garbage value is unknown, not normal" "unknown" \
   "$(printf 'SleepDisabled\t7\n' | parse_sleep_disabled)"
is "key seen but no usable value (truncated) is unknown, not normal — matches Swift's parity" "unknown" \
   "$(printf 'SleepDisabled\n' | parse_sleep_disabled)"
is "an unrelated key that merely contains the substring is not matched" "normal" \
   "$(printf 'NotSleepDisabled\t\t1\n' | parse_sleep_disabled)"

# ---------------------------------------------------------------------------
section "parse_battery_percent"
# ---------------------------------------------------------------------------

is "on AC with a battery" "85" "$(parse_battery_percent < "$FIXTURES/pmset-ps-ac.txt")"
is "on battery"           "18" "$(parse_battery_percent < "$FIXTURES/pmset-ps-battery.txt")"
is "desktop has none"     ""   "$(parse_battery_percent < "$FIXTURES/pmset-ps-desktop.txt")"

# ---------------------------------------------------------------------------
section "probes under 'set -o pipefail' (regression: producer | grep -q)"
# ---------------------------------------------------------------------------
#
# grep -q exits at its first match. The producer then dies of SIGPIPE, and
# pipefail surfaces the producer's non-zero status — so a match reads as "not
# found". This silently broke is_caffeinated, power_source (then on_battery),
# has_battery and has_lid. `ioreg` is the worst case: tens of kilobytes,
# matched on line 19.

export FAKE_IOREG="$FIXTURES/ioreg-clamshell-macbook.txt"
succeeds "has_lid true on a MacBook" has_lid

export FAKE_IOREG="$FIXTURES/ioreg-desktop.txt"
fails "has_lid false on a desktop" has_lid
unset FAKE_IOREG

export FAKE_PMSET_CUSTOM="$MACBOOK"
succeeds "has_battery true on a MacBook" has_battery
export FAKE_PMSET_CUSTOM="$MACMINI"
fails "has_battery false on a desktop" has_battery
unset FAKE_PMSET_CUSTOM

export FAKE_PMSET_PS="$FIXTURES/pmset-ps-battery.txt"
is "power_source: battery when discharging" "battery" "$(power_source)"
export FAKE_PMSET_PS="$FIXTURES/pmset-ps-ac.txt"
is "power_source: ac"                       "ac"      "$(power_source)"
unset FAKE_PMSET_PS

printf '12345' > "$HOME/.lidless_caffeinate_pid"
export FAKE_PS_COMM="caffeinate"
succeeds "is_caffeinated true for a live process" is_caffeinated
export FAKE_PS_COMM=""
fails "is_caffeinated false for a stale pid" is_caffeinated
export FAKE_PS_COMM="/usr/local/bin/my-caffeinate-wrapper"
fails "is_caffeinated false for a name that merely contains caffeinate" is_caffeinated
export FAKE_PS_COMM="/usr/bin/caffeinate"
succeeds "is_caffeinated true for the real full path" is_caffeinated
export FAKE_PS_COMM=""
rm -f "$HOME/.lidless_caffeinate_pid"
fails "is_caffeinated false with no pid file" is_caffeinated
unset FAKE_PS_COMM

# ---------------------------------------------------------------------------
section "power_source: probe failure is unknown, not AC"
# ---------------------------------------------------------------------------
#
# A failed `pmset -g ps` used to read as "" -> not-Battery-Power -> AC,
# indistinguishable from a genuinely-on-AC Mac and silently disabling
# battery-percent auto-off. See docs/ARCHITECTURE.md.

export FAKE_PMSET_FAIL=1
is "power_source: unknown when pmset fails outright" "unknown" "$(power_source)"
unset FAKE_PMSET_FAIL

ADVERSARIAL_PS="$TMP/adversarial-pmset-ps.txt"
printf 'error involving AC Power and Battery Power\n' > "$ADVERSARIAL_PS"
export FAKE_PMSET_PS="$ADVERSARIAL_PS"
is "power_source: an error message that merely mentions both phrases is not a confirmed reading" "unknown" \
   "$(power_source)"
unset FAKE_PMSET_PS

# ---------------------------------------------------------------------------
section "lid_state (tri-state: ignored | normal | unknown)"
# ---------------------------------------------------------------------------
#
# Wraps parse_sleep_disabled with the live `pmset -g` call and its own exit
# status — a probe that fails outright must also read unknown, not just a
# probe that succeeds with malformed output (parse_sleep_disabled's job,
# tested above).

export FAKE_PMSET_G="$FIXTURES/pmset-g-sleepdisabled-on.txt"
is "lid_state: ignored" "ignored" "$(lid_state)"
export FAKE_PMSET_G="$FIXTURES/pmset-g-sleepdisabled-off.txt"
is "lid_state: normal"  "normal"  "$(lid_state)"
unset FAKE_PMSET_G

export FAKE_PMSET_FAIL=1
is "lid_state: unknown when pmset fails outright" "unknown" "$(lid_state)"
unset FAKE_PMSET_FAIL

# ---------------------------------------------------------------------------
section "automatic shutdown helper: requests halt before restoring lid sleep"
# ---------------------------------------------------------------------------

HELPER_ORDER="$TMP/poweroff-order"
: > "$HELPER_ORDER"
if (
  # shellcheck source=../tools/lidless-poweroff
  source "$ROOT/tools/lidless-poweroff"
  id() { printf '0\n'; }
  request_system_shutdown() { printf 'shutdown\n' >> "$HELPER_ORDER"; }
  restore_normal_lid_sleep() { printf 'restore-lid\n' >> "$HELPER_ORDER"; }
  power_off
); then
  ok "helper accepts the shutdown request"
else
  bad "helper unexpectedly rejected the shutdown request"
fi
is "halt is requested before the closed-lid sleep guard is removed" \
   $'shutdown\nrestore-lid' "$(cat "$HELPER_ORDER")"

: > "$HELPER_ORDER"
if (
  # shellcheck source=../tools/lidless-poweroff
  source "$ROOT/tools/lidless-poweroff"
  id() { printf '0\n'; }
  request_system_shutdown() { printf 'shutdown\n' >> "$HELPER_ORDER"; return 1; }
  restore_normal_lid_sleep() { printf 'restore-lid\n' >> "$HELPER_ORDER"; }
  power_off
); then
  bad "helper reported success after the shutdown request failed"
else
  ok "helper reports a rejected shutdown request"
fi
is "a rejected halt leaves the active lid guard untouched for retry" \
   "shutdown" "$(cat "$HELPER_ORDER")"

: > "$HELPER_ORDER"
if (
  # shellcheck source=../tools/lidless-poweroff
  source "$ROOT/tools/lidless-poweroff"
  id() { printf '0\n'; }
  request_system_shutdown() { printf 'shutdown\n' >> "$HELPER_ORDER"; }
  restore_normal_lid_sleep() { printf 'restore-lid\n' >> "$HELPER_ORDER"; return 1; }
  power_off
); then
  ok "an accepted halt is not reclassified as failed when best-effort cleanup fails"
else
  bad "helper reclassified an accepted halt as failed"
fi
is "best-effort lid cleanup still runs after the accepted halt" \
   $'shutdown\nrestore-lid' "$(cat "$HELPER_ORDER")"

OUTDATED_HELPER="$TMP/outdated-poweroff-helper"
printf '%s\n' '#!/bin/bash' 'LIDLESS_POWEROFF_VERSION="1"' > "$OUTDATED_HELPER"
AUTOMATIC_SHUTDOWN_HELPER_VERSION_CHECK_PATH="$OUTDATED_HELPER"
fails "an outdated installed helper is rejected before automatic shutdown" \
      automatic_shutdown_helper_is_current
AUTOMATIC_SHUTDOWN_HELPER_VERSION_CHECK_PATH="$ROOT/tools/lidless-poweroff"
succeeds "the current helper version is accepted" automatic_shutdown_helper_is_current

# ---------------------------------------------------------------------------
section "permission installer: resolves the login user safely"
# ---------------------------------------------------------------------------

INSTALLER_USER="$(
  source "$ROOT/tools/install-auto-shutdown.sh"
  id() {
    if [ "${1:-}" = "-u" ]; then printf '0\n'; else printf 'root\n'; fi
  }
  SUDO_USER="alice" resolve_install_user
)"
is "sudo invocation writes the rule for SUDO_USER, not root" "alice" "$INSTALLER_USER"

INSTALLER_RULE="$(
  source "$ROOT/tools/install-auto-shutdown.sh"
  build_sudoers_rule "alice"
)"
mentions "the one-time rule permits password-free Enable" \
         "/usr/bin/pmset -a disablesleep 1" "$INSTALLER_RULE"
mentions "the one-time rule permits password-free Disable" \
         "/usr/bin/pmset -a disablesleep 0" "$INSTALLER_RULE"
mentions "the one-time rule permits the fixed shutdown helper without arguments" \
         "/Library/PrivilegedHelperTools/io.github.lidless.poweroff \"\"" "$INSTALLER_RULE"

if (
  source "$ROOT/tools/install-auto-shutdown.sh"
  id() {
    if [ "${1:-}" = "-u" ]; then printf '0\n'; else printf 'root\n'; fi
  }
  unset SUDO_USER
  resolve_install_user
) >/dev/null 2>&1; then
  bad "a root shell without SUDO_USER was accepted"
else
  ok "a root shell without SUDO_USER is rejected"
fi

# ---------------------------------------------------------------------------
section "permission installer: refuses a helper that is not the shipped one"
# ---------------------------------------------------------------------------

# The installed bundle sits in a group-writable /Applications, so the helper it
# is about to make root:wheel 0755 with a permanent NOPASSWD rule is a file a
# local process can rewrite. build.sh records its digest; the installer checks
# it before the first sudo.
INTEGRITY_DIR="$TMP/installer-integrity"
mkdir -p "$INTEGRITY_DIR"
cp "$ROOT/tools/lidless-poweroff" "$INTEGRITY_DIR/lidless-poweroff"
( cd "$INTEGRITY_DIR" && /usr/bin/shasum -a 256 lidless-poweroff > lidless-manifest.sha256 )

verify_with_manifest() {
  (
    source "$ROOT/tools/install-auto-shutdown.sh"
    SOURCE_MANIFEST="$1"
    SCRIPT_DIR="$2"
    verify_source_helper "$3"
  )
}

succeeds "the shipped helper matches its generated manifest" \
         verify_with_manifest "$INTEGRITY_DIR/lidless-manifest.sha256" "$INTEGRITY_DIR" \
                              "$INTEGRITY_DIR/lidless-poweroff"

printf '\n# one appended byte\n' >> "$INTEGRITY_DIR/lidless-poweroff"
fails "an altered helper is refused" \
      verify_with_manifest "$INTEGRITY_DIR/lidless-manifest.sha256" "$INTEGRITY_DIR" \
                           "$INTEGRITY_DIR/lidless-poweroff"

INTEGRITY_OUT="$(verify_with_manifest "$INTEGRITY_DIR/lidless-manifest.sha256" "$INTEGRITY_DIR" \
                                      "$INTEGRITY_DIR/lidless-poweroff" 2>&1 || true)"
mentions "the refusal names the file it will not install" \
         "$INTEGRITY_DIR/lidless-poweroff" "$INTEGRITY_OUT"
mentions "the refusal says the file would have become root" \
         "installed as root" "$INTEGRITY_OUT"

verify_with_manifest "$INTEGRITY_DIR/lidless-manifest.sha256" "$INTEGRITY_DIR" \
                     "$INTEGRITY_DIR/lidless-poweroff" >/dev/null 2>&1 \
  && INTEGRITY_STATUS=0 || INTEGRITY_STATUS=$?
is "a digest mismatch has its own exit code, not 1 or 2" "3" "$INTEGRITY_STATUS"

: > "$INTEGRITY_DIR/lidless-manifest.sha256"
fails "a manifest with no entry for the helper is refused" \
      verify_with_manifest "$INTEGRITY_DIR/lidless-manifest.sha256" "$INTEGRITY_DIR" \
                           "$INTEGRITY_DIR/lidless-poweroff"

# A source checkout has no manifest — build.sh writes it into the bundle — so
# running ./tools/install-auto-shutdown.sh from a clone still works.
succeeds "a checkout without a manifest still installs" \
         verify_with_manifest "$INTEGRITY_DIR/absent-manifest" "$ROOT/tools" \
                              "$ROOT/tools/lidless-poweroff"

# Inside a bundle a missing manifest is not a checkout, it is a bundle someone
# emptied — the cheapest way around a digest check is to delete the digest.
INTEGRITY_BUNDLE="$TMP/Lidless.app/Contents/Resources"
mkdir -p "$INTEGRITY_BUNDLE"
: > "$TMP/Lidless.app/Contents/Info.plist"
cp "$ROOT/tools/lidless-poweroff" "$INTEGRITY_BUNDLE/lidless-poweroff"
fails "a bundle whose manifest was deleted is refused" \
      verify_with_manifest "$INTEGRITY_BUNDLE/lidless-manifest.sha256" "$INTEGRITY_BUNDLE" \
                           "$INTEGRITY_BUNDLE/lidless-poweroff"

# The check is worthless if it runs after the install. main() has no test seam
# for sudo (every call is an absolute /usr/bin/sudo, deliberately), so assert
# the ordering against the source itself.
INSTALLER_MAIN="$(sed -n '/^main() {/,/^}/p' "$ROOT/tools/install-auto-shutdown.sh")"
INTEGRITY_VERIFY_LINE="$(printf '%s\n' "$INSTALLER_MAIN" | grep -n 'verify_source_helper' | head -n 1 | cut -d: -f1)"
INTEGRITY_SUDO_LINE="$(printf '%s\n' "$INSTALLER_MAIN" | grep -n '/usr/bin/sudo' | head -n 1 | cut -d: -f1)"
if [ -n "$INTEGRITY_VERIFY_LINE" ] && [ -n "$INTEGRITY_SUDO_LINE" ] \
   && [ "$INTEGRITY_VERIFY_LINE" -lt "$INTEGRITY_SUDO_LINE" ]; then
  ok "the digest check runs before the first sudo call in main()"
else
  bad "the digest check does not precede main()'s first sudo call"
fi

# build.sh must keep producing the manifest the installer now requires.
mentions "build.sh generates the manifest inside the signed bundle" \
         "shasum -a 256 lidless-poweroff > lidless-manifest.sha256" "$(cat "$ROOT/build.sh")"

# ---------------------------------------------------------------------------
section "resolve_started_at: future-timestamp repair (mirrors ensureEnabledAt)"
# ---------------------------------------------------------------------------

RSA_NOW=1800000000
is "within tolerance: left unchanged" "$((RSA_NOW + 60)) unchanged" \
   "$(resolve_started_at $((RSA_NOW + 60)) "$RSA_NOW")"
is "exactly at the tolerance boundary: left unchanged" "$((RSA_NOW + ENABLED_AT_FUTURE_TOLERANCE)) unchanged" \
   "$(resolve_started_at $((RSA_NOW + ENABLED_AT_FUTURE_TOLERANCE)) "$RSA_NOW")"
is "just past the tolerance boundary: repaired to now" "$RSA_NOW repaired" \
   "$(resolve_started_at $((RSA_NOW + ENABLED_AT_FUTURE_TOLERANCE + 1)) "$RSA_NOW")"
is "far in the future: repaired to now, not left to suppress the guard forever" "$RSA_NOW repaired" \
   "$(resolve_started_at $((RSA_NOW + 99 * 3600)) "$RSA_NOW")"
is "in the past: always unchanged" "$((RSA_NOW - 99999)) unchanged" \
   "$(resolve_started_at $((RSA_NOW - 99999)) "$RSA_NOW")"

# ---------------------------------------------------------------------------
section "is_new_session (mirrors Sources/main.swift's sessionWasInactive)"
# ---------------------------------------------------------------------------

fails "lid ignored, caffeinate not running: not new (already ignored)" \
      is_new_session ignored 0
fails "lid ignored, caffeinate running: not new" \
      is_new_session ignored 1
fails "lid normal, caffeinate already running: not new (already active)" \
      is_new_session normal 1
fails "lid unknown, caffeinate already running: not new" \
      is_new_session unknown 1
succeeds "lid normal, caffeinate not running: genuinely new session" \
         is_new_session normal 0
succeeds "lid unknown, caffeinate not running: genuinely new session too" \
         is_new_session unknown 0

# ---------------------------------------------------------------------------
section "stop_our_caffeinate: confirms the process actually exited"
# ---------------------------------------------------------------------------
#
# kill's own exit status used to be trusted outright. Success is now decided
# by re-reading the process table, the same rule set_screenlock and off()'s
# lid-restore check already follow. Poll cadence shortened so this does not
# spend a real second per assertion.

export CAFFEINATE_EXIT_POLL_ATTEMPTS=3
export CAFFEINATE_EXIT_POLL_SECONDS=0.01

DEAD_MARKER="$TMP/caffeinate-died"
rm -f "$DEAD_MARKER"
printf '12345' > "$HOME/.lidless_caffeinate_pid"
export FAKE_PS_COMM="caffeinate"
export FAKE_KILL_DEAD_MARKER="$DEAD_MARKER"
export FAKE_PS_DEAD_MARKER="$DEAD_MARKER"
succeeds "succeeds once the process is confirmed gone" stop_our_caffeinate
is "and the pid file is removed" "absent" \
   "$( [ -f "$HOME/.lidless_caffeinate_pid" ] && echo present || echo absent )"
unset FAKE_KILL_DEAD_MARKER FAKE_PS_DEAD_MARKER
rm -f "$DEAD_MARKER"

printf '12345' > "$HOME/.lidless_caffeinate_pid"
export FAKE_PS_COMM="caffeinate"
fails "fails when the process is still alive after the poll window (kill \"succeeded\", nothing died)" \
      stop_our_caffeinate
is "and the pid file is kept, not silently dropped — still ours, still running" "present" \
   "$( [ -f "$HOME/.lidless_caffeinate_pid" ] && echo present || echo absent )"

rm -f "$HOME/.lidless_caffeinate_pid"

# Stop-all must verify every PID it signalled instead of reporting success from
# kill's exit status. No managed PID is present in these two cases.
SET_STOP_ALL_CAFFEINATE=1
export FAKE_PGREP_OUT="424242"
export FAKE_KILL_LOG="$TMP/stop-all-kill.log"
: > "$FAKE_KILL_LOG"
export FAKE_KILL_DENY=1
export FAKE_PS_COMM="caffeinate"
STOP_ALL_OUT="$(stop_our_caffeinate 2>&1)"; STOP_ALL_RC=$?
is "stop-all failure is propagated" "1" "$STOP_ALL_RC"
mentions "and reports the PID that survived" "424242" "$STOP_ALL_OUT"
lacks "and does not claim the other process stopped" "also stopped other" "$STOP_ALL_OUT"
mentions "and the process was actually signalled" "424242" "$(cat "$FAKE_KILL_LOG")"

# Mixed outcome: the first managed-process poll times out, stop-all then gets
# that managed PID, but an unrelated PID survives. The return must remain
# partial because of the survivor, while our own now-stale PID file is removed
# independently. Override only the pure process-identity probe in this
# subshell so the sequence is deterministic and no real process is touched.
unset FAKE_KILL_DENY
printf '12345' > "$HOME/.lidless_caffeinate_pid"
export FAKE_PGREP_OUT=$'12345\n424242'
STOP_ALL_OUT="$(
  managed_checks=0
  is_caffeinate_pid() {
    local candidate_pid="$1"
    if [ "$candidate_pid" = "12345" ]; then
      managed_checks=$(( managed_checks + 1 ))
      [ "$managed_checks" -le $(( CAFFEINATE_EXIT_POLL_ATTEMPTS + 1 )) ]
      return
    fi
    [ "$candidate_pid" = "424242" ]
  }
  stop_our_caffeinate 2>&1
)"; STOP_ALL_RC=$?
is "a surviving unrelated process keeps the mixed stop-all result partial" "1" "$STOP_ALL_RC"
mentions "and that unrelated survivor is identified" "424242" "$STOP_ALL_OUT"
is "but the managed PID file is removed once our process is confirmed gone" "absent" \
   "$( [ -f "$HOME/.lidless_caffeinate_pid" ] && echo present || echo absent )"

export FAKE_PGREP_OUT="424242"
STOP_ALL_DEAD_MARKER="$TMP/stop-all-died"
rm -f "$STOP_ALL_DEAD_MARKER"
export FAKE_KILL_DEAD_MARKER="$STOP_ALL_DEAD_MARKER"
export FAKE_PS_DEAD_MARKER="$STOP_ALL_DEAD_MARKER"
STOP_ALL_OUT="$(stop_our_caffeinate 2>&1)"; STOP_ALL_RC=$?
is "verified stop-all success returns 0" "0" "$STOP_ALL_RC"
mentions "and only then reports the other process stopped" "also stopped other" "$STOP_ALL_OUT"

# pgrep exit 1 is the legitimate no-match case; any other failure means the
# requested target set was never established and stop-all cannot claim full
# success.
export FAKE_PGREP_OUT=""
export FAKE_PGREP_STATUS=2
STOP_ALL_OUT="$(stop_our_caffeinate 2>&1)"; STOP_ALL_RC=$?
is "stop-all propagates a caffeinate enumeration failure" "1" "$STOP_ALL_RC"
mentions "and explains that pgrep could not enumerate targets" "COULD NOT enumerate" "$STOP_ALL_OUT"

SET_STOP_ALL_CAFFEINATE=0
rm -f "$STOP_ALL_DEAD_MARKER"
unset FAKE_PGREP_OUT FAKE_KILL_LOG FAKE_KILL_DEAD_MARKER FAKE_PS_DEAD_MARKER \
      FAKE_PS_COMM FAKE_PGREP_STATUS
export CAFFEINATE_EXIT_POLL_ATTEMPTS=20
export CAFFEINATE_EXIT_POLL_SECONDS=0.05

# ---------------------------------------------------------------------------
section "with_lock: a held lock refuses a concurrent on/off"
# ---------------------------------------------------------------------------
#
# /usr/bin/lockf -t 0 <fd> is real, unfaked here — it only ever touches the
# isolated lock file under this test's sandboxed $HOME, the same class of
# operation as mkdir/rm. It wraps the real flock(2) kernel lock (confirmed by
# lockf(1)'s own man page, and verified empirically during implementation
# against Sources/SystemProbe.swift's native flock() call on the same file —
# see docs/ARCHITECTURE.md) — a same-process re-acquire
# would not exercise the real hazard (flock is per-open-file-description, not
# per-pid, so a hand-rolled "second call from the same shell" test would
# prove nothing); a genuinely separate background process is used instead.

# Readiness handshake, not a blind sleep-then-hope — an earlier version slept
# a fixed duration and hoped the holder had acquired by then, which was
# flaky (occasional false pass when the subshell was slow to start). See the
# "with_lock interop" section below, where this exact race was caught.
LOCK_HOLDER_READY="$TMP/lock-holder-ready-samelang"
rm -f "$LOCK_HOLDER_READY"
bash -c '
  source "'"$ROOT"'/lidless.sh"
  exec 9>>"$LOCK_FILE"
  /usr/bin/lockf -t 0 9
  : > "'"$LOCK_HOLDER_READY"'"
  sleep 0.5
' &
LOCK_HOLDER_PID=$!
LOCK_HOLDER_HELD=0
for _ in $(seq 1 100); do
  [ -f "$LOCK_HOLDER_READY" ] && { LOCK_HOLDER_HELD=1; break; }
  sleep 0.02
done

if [ "$LOCK_HOLDER_HELD" = "1" ]; then
  bash -c '
    source "'"$ROOT"'/lidless.sh"
    with_lock true
  '
  # Assert the exact lockf EX_TEMPFAIL code (75), not just "some nonzero" —
  # a regression back to collapsing it to a plain 1 (what review
  # round 1 fixed) would otherwise still pass this test. review
  # round 2 caught the gap.
  is "refuses when the lock is already held by another process, with lockf's exact EX_TEMPFAIL code" \
     "75" "$?"
else
  bad "lock holder never signaled ready — contention test could not run"
fi
wait "$LOCK_HOLDER_PID"

succeeds "acquires again once the holder exits and releases it" bash -c '
  source "'"$ROOT"'/lidless.sh"
  with_lock true
'

is "the lock file itself is kept, not deleted (docs/ARCHITECTURE.md's one exception)" "present" \
   "$( [ -e "$HOME/.lidless_lock" ] && echo present || echo absent )"

# ---------------------------------------------------------------------------
section "the pipefail trap is real, and this suite would catch a relapse"
# ---------------------------------------------------------------------------
#
# Proves the hazard rather than assuming it: the same input, through the old
# pipe form and the current one. The fixture is padded past the pipe buffer so
# the producer is guaranteed to still be writing when grep exits — on the real
# system `ioreg` alone is enough, but a 152-line fixture is not.

BIG="$TMP/ioreg-big.txt"
{
  cat "$FIXTURES/ioreg-clamshell-macbook.txt"
  i=0
  while [ $i -lt 20000 ]; do
    echo '  |   "Padding" = "so the producer outlives grep -q"'
    i=$((i + 1))
  done
} > "$BIG"

export FAKE_IOREG="$BIG"

# The old, broken form. If this ever starts succeeding the demonstration below
# is no longer meaningful, so report that instead of quietly passing.
buggy_has_lid() { ioreg -r -k AppleClamshellState 2>/dev/null | grep -q AppleClamshellState; }

if buggy_has_lid; then
  bad "old '| grep -q' form did NOT break — this regression test proves nothing now"
else
  ok "old '| grep -q' form reports not-found on input that clearly matches"
fi

succeeds "current has_lid gets it right on the same input" has_lid
unset FAKE_IOREG

# ---------------------------------------------------------------------------
section "sysadminctl exits 0 when it refuses (never trust its status)"
# ---------------------------------------------------------------------------
#
# `sysadminctl -screenLock 3600` with no usable password writes "Password is
# required!" to stderr and still exits 0. Verified on macOS 26.5. set_screenlock
# must therefore decide success by re-reading the value.
#
# set_screenlock declines without a terminal, and the interesting behaviour is
# on the other side of that guard. Rather than conjure a pty — `script` cannot
# always allocate one on a loaded machine or a CI runner, and when it failed all
# three assertions below collapsed together — override the seam the guard uses.
# The real `have_tty` is still exercised by the no-tty test further down.
have_tty() { return 0; }

set_screenlock_quietly() { set_screenlock 3600 >/dev/null 2>&1; }

export FAKE_SYSADMINCTL_STATUS="$FIXTURES/sysadminctl-900.txt"
export FAKE_SYSADMINCTL_REFUSE=1
export FAKE_SYSADMINCTL_STATE=""
fails "refused set reports failure despite exit 0" set_screenlock_quietly

# Same code path, but this time the value really moves.
export FAKE_SYSADMINCTL_REFUSE=0
export FAKE_SYSADMINCTL_STATE="$TMP/screenlock-state"
printf '900' > "$FAKE_SYSADMINCTL_STATE"
succeeds "applied set reports success" set_screenlock_quietly
is "and the value actually changed" "3600" "$(cat "$FAKE_SYSADMINCTL_STATE")"

# Back to the real thing for the guard test below.
unset -f have_tty
source "$ROOT/lidless.sh"
set +e

# Without a terminal it must decline rather than silently appear to work.
# stdin is redirected from /dev/null explicitly: run interactively, the test
# shell's stdin *is* a tty and the check would otherwise invert.
export FAKE_SYSADMINCTL_REFUSE=0
printf '900' > "$FAKE_SYSADMINCTL_STATE"
set_screenlock_without_tty() { set_screenlock 3600 >/dev/null 2>&1 </dev/null; }

fails "declines when there is no tty for the password prompt" set_screenlock_without_tty
is "and it changed nothing" "900" "$(cat "$FAKE_SYSADMINCTL_STATE")"

unset FAKE_SYSADMINCTL_STATUS FAKE_SYSADMINCTL_REFUSE FAKE_SYSADMINCTL_STATE

# ---------------------------------------------------------------------------
section "settings shared with the app"
# ---------------------------------------------------------------------------
#
# The script used to have its own edit-the-file constants, so ticking a box in
# the app and then running `lidless.sh on` silently did not apply it.

succeeds "truthy 1"     truthy 1
succeeds "truthy true"  truthy true
succeeds "truthy YES"   truthy YES
fails    "truthy 0"     truthy 0
fails    "truthy false" truthy false
fails    "truthy empty" truthy ""
fails    "truthy junk"  truthy banana

is "screenlock_target maps the app's 0 to off" "off"  "$(screenlock_target 0)"
is "screenlock_target passes seconds through"  "3600" "$(screenlock_target 3600)"
is "never_or on 0"    "never" "$(never_or 0)"
is "never_or on a value" "20%" "$(never_or 20 '%')"

# No domain at all — someone who has never run the app.
export FAKE_DEFAULTS="$TMP/no-such-domain"
is "absent domain falls back"      "banana" "$(read_default lowPowerWhileActive banana)"
load_settings
is "fallback: low power"           "0"    "$SET_LOW_POWER"
is "fallback: screen lock"         "0"    "$SET_SCREENLOCK"
is "fallback: screen lock delay"   "3600" "$SET_SCREENLOCK_DELAY"
is "fallback: keep awake on batt"  "1"    "$SET_KEEP_AWAKE_ON_BATTERY"
mentions "fallback source is named" "fallbacks" "$SETTINGS_SOURCE"

# Domain present, but only some keys set: the rest must still fall back.
export FAKE_DEFAULTS="$TMP/defaults-partial"
cat > "$FAKE_DEFAULTS" <<'EOF'
lowPowerWhileActive 1
automaticShutdownAfterHoursV1 4
autoOffHours 99
EOF
is "present key wins"              "1" "$(read_default lowPowerWhileActive 0)"
is "missing key falls back"        "7" "$(read_default relaxScreenLock 7)"
load_settings
is "app: low power on"             "1" "$SET_LOW_POWER"
is "app: shutdown hours"           "4" "$SET_SHUTDOWN_AFTER_HOURS"
is "legacy soft-disable key is ignored" "4" "$SET_SHUTDOWN_AFTER_HOURS"
is "unset key keeps the fallback"  "0" "$SET_SCREENLOCK"
mentions "app source is named" "io.github.lidless" "$SETTINGS_SOURCE"

# The whole point: the app's "Never" delay must reach sysadminctl as "off".
export FAKE_DEFAULTS="$TMP/defaults-never"
printf 'relaxScreenLock 1\nscreenLockDelay 0\n' > "$FAKE_DEFAULTS"
load_settings
is "app: relax screen lock on"     "1"     "$SET_SCREENLOCK"
is "app: delay 0 becomes off"      "off"   "$(screenlock_target "$SET_SCREENLOCK_DELAY")"

# The two app-only keys. The script cannot act on either, but status() has to
# report what the APP would resolve them to, which means mirroring
# SystemProbe.panelMode(in:) rather than echoing the raw string back.
is "panel mode: absent is the default"  "virtual" "$(panel_mode_value "")"
is "panel mode: virtual round-trips"    "virtual" "$(panel_mode_value virtual)"
is "panel mode: dim round-trips"        "dim"     "$(panel_mode_value dim)"
is "panel mode: whitespace tolerated, like every other state value" \
   "dim" "$(panel_mode_value '  dim
')"
# Never a refusal and never a passthrough: the app resolves a typo to the
# default, so the script must show the same thing the app would act on.
is "panel mode: an unknown value reads as the default" "virtual" \
   "$(panel_mode_value sideways)"

export FAKE_DEFAULTS="$TMP/defaults-panel"
printf 'blackoutBuiltinDisplayV1 1\npanelModeV1 dim\n' > "$FAKE_DEFAULTS"
load_settings
is "app: panel blackout on"        "1"   "$SET_BLACKOUT_BUILTIN_DISPLAY"
is "app: panel mode dim"           "dim" "$SET_PANEL_MODE"

export FAKE_DEFAULTS="$TMP/no-such-domain"
load_settings
is "no domain: panel blackout off" "0"       "$SET_BLACKOUT_BUILTIN_DISPLAY"
is "no domain: panel mode default" "virtual" "$SET_PANEL_MODE"

unset FAKE_DEFAULTS
load_settings   # leave the globals holding fallbacks for anything after this

# ---------------------------------------------------------------------------
section "auto-off watchdog"
# ---------------------------------------------------------------------------
#
# auto_off_reason takes every input as a parameter, so these run in milliseconds
# instead of waiting eight hours or flattening a battery.

NOW=1800000000
HOUR=3600

SET_SHUTDOWN_AFTER_HOURS=0
SET_SHUTDOWN_BELOW_BATTERY_PERCENT=0
is "both limits off: never fires" "" "$(auto_off_reason $((NOW - 99 * HOUR)) "$NOW" 1 5)"

SET_SHUTDOWN_AFTER_HOURS=4
SET_SHUTDOWN_BELOW_BATTERY_PERCENT=0
is "under the hours limit"    ""  "$(auto_off_reason $((NOW - 3 * HOUR)) "$NOW" 0 90)"
is "exactly at the limit"     "on for 4h (limit 4h)" "$(auto_off_reason $((NOW - 4 * HOUR)) "$NOW" 0 90)"
is "past the limit"           "on for 9h (limit 4h)" "$(auto_off_reason $((NOW - 9 * HOUR)) "$NOW" 0 90)"
is "no start time: cannot judge elapsed" "" "$(auto_off_reason "" "$NOW" 0 90)"
is "junk start time is ignored"          "" "$(auto_off_reason "not-a-number" "$NOW" 0 90)"

SET_SHUTDOWN_AFTER_HOURS=0
SET_SHUTDOWN_BELOW_BATTERY_PERCENT=20
is "above the battery limit"  ""  "$(auto_off_reason "$NOW" "$NOW" 1 55)"
is "at the battery limit"     "battery at 20% (limit 20%)" "$(auto_off_reason "$NOW" "$NOW" 1 20)"
is "below the battery limit"  "battery at 9% (limit 20%)"  "$(auto_off_reason "$NOW" "$NOW" 1 9)"
# A Mac on AC at 9% is charging, not dying. Switching off there would drop the
# remote session for no reason.
is "low battery but on AC: leave it alone" "" "$(auto_off_reason "$NOW" "$NOW" 0 9)"
is "no battery reading at all"             "" "$(auto_off_reason "$NOW" "$NOW" 1 "")"

SET_SHUTDOWN_AFTER_HOURS=4
SET_SHUTDOWN_BELOW_BATTERY_PERCENT=20
is "hours reported first when both trip" "on for 5h (limit 4h)" \
   "$(auto_off_reason $((NOW - 5 * HOUR)) "$NOW" 1 5)"
is "battery trips while hours are fine"  "battery at 5% (limit 20%)" \
   "$(auto_off_reason $((NOW - 1 * HOUR)) "$NOW" 1 5)"

succeeds "is_positive_int 5"  is_positive_int 5
fails    "is_positive_int 0"  is_positive_int 0
fails    "is_positive_int ''" is_positive_int ""
fails    "is_positive_int -1" is_positive_int -- -1
fails    "is_positive_int 1x" is_positive_int 1x

succeeds "is_plausible_epoch: a real-looking timestamp" is_plausible_epoch 1800000000
fails    "is_plausible_epoch: an 11-digit value is rejected, not wrapped" \
         is_plausible_epoch 18000000000

# ---------------------------------------------------------------------------
section "off(): explicit tri-state exit code (Phase 8)"
# ---------------------------------------------------------------------------
#
# Called directly (not through the watchdog wrapper) so the exit code itself
# is under test, not just the message text a caller derives from it.

export FAKE_PS_COMM=""
export FAKE_PGREP_OUT=""
export FAKE_DEFAULTS="$TMP/off-defaults"
: > "$FAKE_DEFAULTS"
export FAKE_SUDO_DENY=0
unset FAKE_SUDO_DENY_MATCH
OFF_PMSET_STATE="$TMP/off-pmset-state"
export FAKE_PMSET_G_STATE="$OFF_PMSET_STATE"
export FAKE_SUDO_PMSET_STATE="$OFF_PMSET_STATE"
rm -f "$HOME/.lidless_caffeinate_pid" "$HOME/.lidless_lowpower_prev" "$HOME/.lidless_screenlock_prev"

# --- everything clean: full success, code 0 --------------------------------
echo 1 > "$OFF_PMSET_STATE"
off </dev/null >/dev/null 2>&1; is "full success returns 0" "0" "$?"

# --- lid already normal (initial state, not ignored): full success, code 0 -
# review round 3 caught the input matrix only ever seeded
# SleepDisabled=1 (ignored) — never the already-normal or unknown initial
# states, even though off()'s own tri-state branches on exactly this.
echo 0 > "$OFF_PMSET_STATE"
OFF_OUT="$(off </dev/null 2>&1)"; OFF_RC_LOCAL=$?
is "already-normal initial state returns 0" "0" "$OFF_RC_LOCAL"
mentions "and does not attempt a needless restore" "already normal" "$OFF_OUT"

# --- initial state unknown: attempts the fail-safe restore, verifies, and --
# --- succeeds once the value is confirmed normal ---------------------------
unset FAKE_PMSET_G_STATE
export FAKE_PMSET_FAIL=1
export FAKE_SUDO_LOG="$TMP/off-unknown-sudo.log"
: > "$FAKE_SUDO_LOG"
OFF_OUT="$(off </dev/null 2>&1)"; OFF_RC_LOCAL=$?
mentions "unknown initial state attempts the restore anyway (fail-safe)" \
         "disablesleep 0" "$(cat "$FAKE_SUDO_LOG")"
# The probe stays unreadable throughout this scenario (FAKE_PMSET_FAIL=1
# never clears), so even a "successful" sudo call can never be confirmed by
# re-reading — this must NOT report full success.
is "and does not confirm success when the probe never clears" "1" "$OFF_RC_LOCAL"
unset FAKE_PMSET_FAIL
export FAKE_PMSET_G_STATE="$OFF_PMSET_STATE"

# --- lid cannot be restored: hard failure, code 1 ---------------------------
echo 1 > "$OFF_PMSET_STATE"
export FAKE_SUDO_DENY=1
off </dev/null >/dev/null 2>&1; is "lid restore failure returns 1" "1" "$?"
export FAKE_SUDO_DENY=0

# --- screen-lock restore fails (no tty): partial, code 2 -------------------
echo 1 > "$OFF_PMSET_STATE"
printf '900' > "$HOME/.lidless_screenlock_prev"
off </dev/null >/dev/null 2>&1; is "screen-lock restore failure returns 2, not 0" "2" "$?"
rm -f "$HOME/.lidless_screenlock_prev"

# --- screen-lock restore point is malformed: not trusted, not restored -----
# review round 8 caught that off() passed a saved screen-lock value
# straight through to set_screenlock without validating it — the same bug
# already fixed for Low Power Mode's validate_saved_lowpower(). A malformed
# value must never even reach set_screenlock, which would otherwise print its
# own "SKIPPED screen lock" tty message here (have_tty() is always false in
# this harness) — that message's absence is the mutation-testable signal.
echo 1 > "$OFF_PMSET_STATE"
printf 'garbage' > "$HOME/.lidless_screenlock_prev"
OFF_OUT="$(off </dev/null 2>&1)"; OFF_RC_LOCAL=$?
mentions "malformed screen-lock restore point is reported as invalid" \
         "Saved screen lock state" "$OFF_OUT"
lacks "and set_screenlock is never even attempted" "SKIPPED screen lock" "$OFF_OUT"
is "the malformed file is kept, not silently discarded" "present" \
   "$( [ -f "$HOME/.lidless_screenlock_prev" ] && echo present || echo absent )"
is "and off() still reports partial (code 2), not full success" "2" "$OFF_RC_LOCAL"
rm -f "$HOME/.lidless_screenlock_prev"

# --- Low Power Mode restore fails (sudoers denies it): partial, code 2 -----
echo 1 > "$OFF_PMSET_STATE"
printf '0:1' > "$HOME/.lidless_lowpower_prev"
export FAKE_SUDO_DENY_MATCH="lowpowermode"
off </dev/null >/dev/null 2>&1; is "Low Power Mode restore failure returns 2, not 0" "2" "$?"
unset FAKE_SUDO_DENY_MATCH
rm -f "$HOME/.lidless_lowpower_prev"

# --- caffeinate does not actually stop: partial, code 2 ---------------------
echo 1 > "$OFF_PMSET_STATE"
printf '12345' > "$HOME/.lidless_caffeinate_pid"
export FAKE_PS_COMM="caffeinate"
export CAFFEINATE_EXIT_POLL_ATTEMPTS=2
export CAFFEINATE_EXIT_POLL_SECONDS=0.01
off </dev/null >/dev/null 2>&1; is "kill-verification failure returns 2, not 0" "2" "$?"
export FAKE_PS_COMM=""
export CAFFEINATE_EXIT_POLL_ATTEMPTS=20
export CAFFEINATE_EXIT_POLL_SECONDS=0.05
rm -f "$HOME/.lidless_caffeinate_pid"

# --- requested stop-all leaves another caffeinate alive: partial -----------
echo 1 > "$OFF_PMSET_STATE"
printf 'stopAllCaffeinate 1\n' > "$FAKE_DEFAULTS"
export FAKE_PGREP_OUT="424242"
export FAKE_PS_COMM="caffeinate"
export FAKE_KILL_DENY=1
export CAFFEINATE_EXIT_POLL_ATTEMPTS=2
export CAFFEINATE_EXIT_POLL_SECONDS=0.01
OFF_OUT="$(off </dev/null 2>&1)"; OFF_RC_LOCAL=$?
is "stop-all verification failure makes off() partial" "2" "$OFF_RC_LOCAL"
mentions "and off() identifies the surviving process" "424242" "$OFF_OUT"

# Enumeration failure is also partial: the lid is safely restored, but the
# explicitly-requested stop-all operation was not completed or verified.
echo 1 > "$OFF_PMSET_STATE"
export FAKE_PS_COMM=""
export FAKE_PGREP_OUT=""
export FAKE_PGREP_STATUS=2
unset FAKE_KILL_DENY
OFF_OUT="$(off </dev/null 2>&1)"; OFF_RC_LOCAL=$?
is "stop-all enumeration failure makes off() partial" "2" "$OFF_RC_LOCAL"
mentions "and off() reports the enumeration failure" "COULD NOT enumerate" "$OFF_OUT"
: > "$FAKE_DEFAULTS"
unset FAKE_KILL_DENY FAKE_PGREP_STATUS
export CAFFEINATE_EXIT_POLL_ATTEMPTS=20
export CAFFEINATE_EXIT_POLL_SECONDS=0.05
export FAKE_PS_COMM=""
export FAKE_PGREP_OUT=""

unset FAKE_PMSET_G_STATE FAKE_SUDO_PMSET_STATE FAKE_DEFAULTS FAKE_PS_COMM FAKE_PGREP_OUT FAKE_SUDO_DENY

# ---------------------------------------------------------------------------
section "on(): ignored/normal/unknown lid matrix (Phase 3)"
# ---------------------------------------------------------------------------
#
# review round 2 caught that the tri-state work never got a direct
# on()/status() matrix, only off()'s. Most cases pre-seed PID_FILE with a fake
# "already running" process. One dedicated case uses tests/bin/caffeinate — a
# harmless short sleep — to exercise the real nohup/start branch without
# creating a real power-management assertion on the machine running the suite.

ON_PMSET_STATE="$TMP/on-pmset-state"
export FAKE_PMSET_G_STATE="$ON_PMSET_STATE"
export FAKE_SUDO_LOG="$TMP/on-sudo.log"
export FAKE_DEFAULTS="$TMP/on-defaults"
: > "$FAKE_DEFAULTS"
export FAKE_PS_COMM="caffeinate"
printf '12345' > "$HOME/.lidless_caffeinate_pid"
rm -f "$HOME/.lidless_enabled_at"

echo 1 > "$ON_PMSET_STATE"
: > "$FAKE_SUDO_LOG"
on </dev/null >/dev/null 2>&1
is "lid already ignored does not re-apply disablesleep" "" "$(cat "$FAKE_SUDO_LOG")"
rm -f "$HOME/.lidless_enabled_at"

echo 0 > "$ON_PMSET_STATE"
export FAKE_SUDO_PMSET_STATE="$ON_PMSET_STATE"
: > "$FAKE_SUDO_LOG"
ON_OUT="$(on </dev/null 2>&1)"; ON_RC=$?
mentions "lid normal applies disablesleep 1" "disablesleep 1" "$(cat "$FAKE_SUDO_LOG")"
mentions "and confirms it by re-reading, not just trusting sudo's exit status" \
         "will now be ignored" "$ON_OUT"
mentions "and prints the success banner" "Lidless is ON" "$ON_OUT"
is "confirmed success returns 0" "0" "$ON_RC"
rm -f "$HOME/.lidless_enabled_at"

# --- caffeinate exits immediately: persistent lid state is tracked, but on()
# must not claim full success or apply optional settings ---------------------
rm -f "$HOME/.lidless_caffeinate_pid"
export FAKE_PS_COMM=""
export FAKE_CAFFEINATE_DURATION=0
export CAFFEINATE_EXIT_POLL_ATTEMPTS=2
export CAFFEINATE_EXIT_POLL_SECONDS=0.01
echo 0 > "$ON_PMSET_STATE"
: > "$FAKE_SUDO_LOG"
ON_OUT="$(on </dev/null 2>&1)"; ON_RC=$?
is "an immediately-dead caffeinate makes on() fail" "1" "$ON_RC"
mentions "and reports the core partial state" "did not stay running" "$ON_OUT"
lacks "and does not print the success banner" "Lidless is ON" "$ON_OUT"
is "the confirmed persistent lid setting remains enabled" "1" "$(cat "$ON_PMSET_STATE")"
is "the safety timestamp is kept for the watchdog" "present" \
   "$( [ -f "$HOME/.lidless_enabled_at" ] && echo present || echo absent )"
is "the confirmed-dead PID is removed before it can be reused by another process" "absent" \
   "$( [ -f "$HOME/.lidless_caffeinate_pid" ] && echo present || echo absent )"
lacks "and on() never performs an unsafe rollback" "disablesleep 0" "$(cat "$FAKE_SUDO_LOG")"
rm -f "$HOME/.lidless_enabled_at" "$HOME/.lidless_caffeinate_pid"
unset FAKE_CAFFEINATE_DURATION
export CAFFEINATE_EXIT_POLL_ATTEMPTS=20
export CAFFEINATE_EXIT_POLL_SECONDS=0.05
export FAKE_PS_COMM="caffeinate"
printf '12345' > "$HOME/.lidless_caffeinate_pid"

# --- sudo "succeeds" but the value never actually moves: not silently 'ON' -
# The other half of "verify by re-reading" (docs/ARCHITECTURE.md's rule) — a
# command that reports success does not guarantee the value moved. review
#  round 3 caught that on() never got this check, unlike off();
# round 4 caught that even after adding the check, an unconfirmed lid still
# fell through to the LPM/screenlock/timestamp work and the "Lidless is ON"
# banner, and returned 0 regardless.
echo 0 > "$ON_PMSET_STATE"
unset FAKE_SUDO_PMSET_STATE
: > "$FAKE_SUDO_LOG"
ON_OUT="$(on </dev/null 2>&1)"; ON_RC=$?
mentions "still attempts disablesleep 1" "disablesleep 1" "$(cat "$FAKE_SUDO_LOG")"
mentions "but does not claim success when the value did not move" \
         "COULD NOT confirm the lid setting was applied" "$ON_OUT"
lacks "and does not print the success banner either" "Lidless is ON" "$ON_OUT"
is "unconfirmed lid setting returns 1, not 0" "1" "$ON_RC"
is "and does not stamp the auto-off timestamp for an unconfirmed session" "absent" \
   "$( [ -f "$HOME/.lidless_enabled_at" ] && echo present || echo absent )"
rm -f "$HOME/.lidless_enabled_at"

unset FAKE_PMSET_G_STATE
export FAKE_PMSET_FAIL=1
: > "$FAKE_SUDO_LOG"
ON_OUT="$(on </dev/null 2>&1)"; ON_RC=$?
mentions "lid unknown attempts disablesleep 1 anyway (fail-safe, not skipped)" \
         "disablesleep 1" "$(cat "$FAKE_SUDO_LOG")"
mentions "and warns about the unreadable probe" "Could not read the current lid setting" "$ON_OUT"
is "and returns 1 — the probe never clears, so it can never be confirmed" "1" "$ON_RC"
unset FAKE_PMSET_FAIL
export FAKE_PMSET_G_STATE="$ON_PMSET_STATE"
rm -f "$HOME/.lidless_enabled_at"

# --- on()'s Low Power Mode save-before-enable path -------------------------
# review round 4 caught that the matrix above never actually
# exercised this: FAKE_DEFAULTS was empty the whole time, so SET_LOW_POWER
# stayed 0 and read_lowpower_snapshot() was never reached by any on() test
# despite fixes-round3.md claiming coverage. Every case here starts from a
# lid state that's already confirmed (ON_PMSET_STATE=0 + FAKE_SUDO_PMSET_STATE),
# so the on() call reaches the LPM block instead of returning early.
export FAKE_DEFAULTS="$TMP/on-lpm-defaults"
printf 'lowPowerWhileActive 1\n' > "$FAKE_DEFAULTS"
export FAKE_SUDO_PMSET_STATE="$ON_PMSET_STATE"
rm -f "$LOWPOWER_FILE"

echo 0 > "$ON_PMSET_STATE"
export FAKE_PMSET_CUSTOM="$FIXTURES/pmset-custom-macbook.txt"
export FAKE_PMSET_PS="$FIXTURES/pmset-ps-battery.txt"
: > "$FAKE_SUDO_LOG"
ON_OUT="$(on </dev/null 2>&1)"
mentions "confirmed laptop: saves a real ac:battery snapshot" \
         "Saved original Low Power Mode: 0:1 (ac:battery)" "$ON_OUT"
is "and the file actually holds it" "0:1" "$(cat "$LOWPOWER_FILE" 2>/dev/null)"
mentions "then enables Low Power Mode" "lowpowermode 1" "$(cat "$FAKE_SUDO_LOG")"
mentions "and says so" "Low Power Mode on" "$ON_OUT"
rm -f "$HOME/.lidless_enabled_at" "$LOWPOWER_FILE"

echo 0 > "$ON_PMSET_STATE"
export FAKE_PMSET_CUSTOM="$FIXTURES/pmset-custom-macmini.txt"
export FAKE_PMSET_PS="$FIXTURES/pmset-ps-desktop.txt"
: > "$FAKE_SUDO_LOG"
ON_OUT="$(on </dev/null 2>&1)"
mentions "confirmed desktop (AC-only, cross-checked no InternalBattery): saves ac:0" \
         "Saved original Low Power Mode: 0:0 (ac:battery)" "$ON_OUT"
mentions "and still enables Low Power Mode" "lowpowermode 1" "$(cat "$FAKE_SUDO_LOG")"
rm -f "$HOME/.lidless_enabled_at" "$LOWPOWER_FILE"

echo 0 > "$ON_PMSET_STATE"
export FAKE_PMSET_CUSTOM="$FIXTURES/pmset-custom-macmini.txt"
export FAKE_PMSET_FAIL_PS=1
: > "$FAKE_SUDO_LOG"
ON_OUT="$(on </dev/null 2>&1)"
mentions "AC-only custom read but the cross-check battery probe fails: refuses to guess" \
         "Could not read the current Low Power Mode" "$ON_OUT"
is "does not save a fabricated snapshot" "absent" \
   "$( [ -f "$LOWPOWER_FILE" ] && echo present || echo absent )"
lacks "and does not enable Low Power Mode without a trustworthy restore point" \
      "lowpowermode 1" "$(cat "$FAKE_SUDO_LOG")"
unset FAKE_PMSET_FAIL_PS
rm -f "$HOME/.lidless_enabled_at" "$LOWPOWER_FILE"

echo 0 > "$ON_PMSET_STATE"
export FAKE_PMSET_CUSTOM="$FIXTURES/pmset-custom-macbook.txt"
export FAKE_PMSET_PS="$FIXTURES/pmset-ps-battery.txt"
printf '1' > "$LOWPOWER_FILE"   # colonless — the pre-round-4 validator bug
: > "$FAKE_SUDO_LOG"
ON_OUT="$(on </dev/null 2>&1)"
mentions "a malformed pre-existing save file is not trusted as-is" \
         "malformed" "$ON_OUT"
is "it gets recaptured with a real, valid snapshot" "0:1" "$(cat "$LOWPOWER_FILE" 2>/dev/null)"
mentions "and Low Power Mode is still enabled" "lowpowermode 1" "$(cat "$FAKE_SUDO_LOG")"
rm -f "$HOME/.lidless_enabled_at" "$LOWPOWER_FILE"

echo 0 > "$ON_PMSET_STATE"
printf '1:0' > "$LOWPOWER_FILE"   # already valid — must be reused, not re-derived
: > "$FAKE_SUDO_LOG"
ON_OUT="$(on </dev/null 2>&1)"
lacks "a valid pre-existing save file is reused as-is, not re-saved" \
      "Saved original Low Power Mode" "$ON_OUT"
is "and its content is left untouched" "1:0" "$(cat "$LOWPOWER_FILE" 2>/dev/null)"
mentions "still enables Low Power Mode" "lowpowermode 1" "$(cat "$FAKE_SUDO_LOG")"
rm -f "$HOME/.lidless_enabled_at" "$LOWPOWER_FILE"

# --- the README's realistic sudoers case: disablesleep allowed, lowpowermode
# not — must not silently kill the rest of on() -----------------------------
# review round 5 caught that both `run_privileged pmset -a
# lowpowermode 1` call sites were bare statements under this file's `set -e`:
# a denied/failed enable (exactly the shape the README's own sudoers rule
# produces, since it only grants `disablesleep`) killed the whole `on()` call
# on the spot — the already-applied lid setting, the safety timestamp, the
# screen-lock save, and the success banner never ran, with no indication why.
#
# This file itself runs under `set +e` (see the top of this file, right after
# sourcing lidless.sh) so that one failing assertion doesn't abort the whole
# suite — which means calling `on`/`with_lock` in *this* process, however
# "production-shaped" the setup looks, does not actually exercise `set -e`;
# review round 6 caught that the first version of this test did
# exactly that, so it could not have told the difference between the fixed
# and the original broken code with respect to the actual failure mode (a
# bare command killing the calling shell). Spawning a genuinely fresh `bash`
# process that sources lidless.sh from scratch is what actually re-enables
# `set -e` for the duration of that process, matching real usage. Covers both
# call sites: the fresh-snapshot path (no pre-existing `$LOWPOWER_FILE`) and
# the pre-existing-valid-file path.
run_on_in_fresh_process() {
  bash -c 'source "'"$ROOT"'/lidless.sh" && with_lock on' </dev/null 2>&1
}

echo 0 > "$ON_PMSET_STATE"
export FAKE_SUDO_DENY_MATCH="lowpowermode"
: > "$FAKE_SUDO_LOG"
ON_OUT="$(run_on_in_fresh_process)"; ON_RC=$?
mentions "fresh snapshot: lid setting is still applied" "disablesleep 1" "$(cat "$FAKE_SUDO_LOG")"
mentions "and explains that Low Power Mode specifically could not be" \
         "Low Power Mode could NOT be enabled" "$ON_OUT"
mentions "but on() itself does not die — it still reaches the safety timestamp" \
         "Lidless is ON" "$ON_OUT"
is "and returns 0, not killed mid-function by set -e in a real fresh process" "0" "$ON_RC"
is "the enabled-at timestamp was actually written" "present" \
   "$( [ -f "$HOME/.lidless_enabled_at" ] && echo present || echo absent )"
rm -f "$HOME/.lidless_enabled_at" "$LOWPOWER_FILE"

echo 0 > "$ON_PMSET_STATE"
printf '0:1' > "$LOWPOWER_FILE"   # pre-existing valid save — the OTHER call site
: > "$FAKE_SUDO_LOG"
ON_OUT="$(run_on_in_fresh_process)"; ON_RC=$?
mentions "pre-existing save file: lid setting is still applied" "disablesleep 1" "$(cat "$FAKE_SUDO_LOG")"
mentions "same failure message from the other call site" \
         "Low Power Mode could NOT be enabled" "$ON_OUT"
mentions "and on() still completes" "Lidless is ON" "$ON_OUT"
is "and returns 0 here too" "0" "$ON_RC"
unset FAKE_SUDO_DENY_MATCH
rm -f "$HOME/.lidless_enabled_at" "$LOWPOWER_FILE"

# --- screen-lock relax must not proceed without a restore point ------------
# review round 7 caught that on() called set_screenlock
# unconditionally even when the original delay could not be read (or, after
# round 6's fix, when saving it failed) — mutating a persistent setting with
# nothing to restore it from later. have_tty() is always false in this test
# harness (</dev/null), so the OLD buggy code still reached set_screenlock
# and printed its own "SKIPPED screen lock ... needs a terminal" message; the
# fix means set_screenlock is never called at all here, so that message must
# be completely absent — a real, mutation-testable distinction.
echo 0 > "$ON_PMSET_STATE"
printf 'relaxScreenLock 1\nscreenLockDelay 0\n' > "$FAKE_DEFAULTS"
export FAKE_SYSADMINCTL_STATUS="$FIXTURES/sysadminctl-password-required.txt"
rm -f "$HOME/.lidless_screenlock_prev"
ON_OUT="$(on </dev/null 2>&1)"
mentions "unreadable screen lock: refuses to save a bogus value" \
         "Could not read the current screen lock delay" "$ON_OUT"
lacks "and never even attempts to relax it (no tty-skip message either)" \
      "SKIPPED screen lock" "$ON_OUT"
is "no restore file was created" "absent" \
   "$( [ -f "$HOME/.lidless_screenlock_prev" ] && echo present || echo absent )"
unset FAKE_SYSADMINCTL_STATUS
rm -f "$HOME/.lidless_enabled_at" "$HOME/.lidless_screenlock_prev"

echo 0 > "$ON_PMSET_STATE"
printf 'relaxScreenLock 1\nscreenLockDelay 0\nautomaticShutdownAfterHoursV1 4\n' \
  > "$FAKE_DEFAULTS"
ON_OUT="$(on </dev/null 2>&1)"
mentions "automatic shutdown prevents a new unattended screen-lock restore debt" \
         "SKIPPED screen-lock relaxation" "$ON_OUT"
is "no screen-lock restore point is created for the incompatible combination" "absent" \
   "$( [ -f "$HOME/.lidless_screenlock_prev" ] && echo present || echo absent )"
rm -f "$HOME/.lidless_enabled_at"

# --- a malformed pre-existing screen-lock save is not trusted as-is --------
# review round 8 caught that a pre-existing SCREENLOCK_FILE was
# trusted based only on `-f` (existence), with no content validation — the
# same bug already fixed for LOWPOWER_FILE. Uses the default sysadminctl
# fixture (a readable "900"), so the recapture has something real to save.
echo 0 > "$ON_PMSET_STATE"
printf 'relaxScreenLock 1\nscreenLockDelay 0\n' > "$FAKE_DEFAULTS"
printf 'garbage' > "$HOME/.lidless_screenlock_prev"
ON_OUT="$(on </dev/null 2>&1)"
mentions "a malformed pre-existing screen-lock save is not trusted as-is" \
         "malformed" "$ON_OUT"
is "it gets recaptured with a real, valid value" "900" \
   "$(cat "$HOME/.lidless_screenlock_prev" 2>/dev/null)"
rm -f "$HOME/.lidless_enabled_at" "$HOME/.lidless_screenlock_prev"

# --- a malformed pre-existing enabled-at timestamp is recaptured -----------
# review round 10 caught that on() only wrote ENABLEDAT_FILE when it
# was entirely absent, never validating an existing-but-corrupt one (e.g.
# left empty by a crash mid-write) — the same bug already fixed for
# LOWPOWER_FILE/SCREENLOCK_FILE. FAKE_DEFAULTS cleared first: this test only
# cares about ENABLEDAT_FILE, not the Low Power Mode/screen-lock settings the
# previous cases in this section left active, which would otherwise create
# their own restore-point files here too.
echo 0 > "$ON_PMSET_STATE"
: > "$FAKE_DEFAULTS"
: > "$HOME/.lidless_enabled_at"   # present, but empty — not a plausible epoch
ON_OUT="$(on </dev/null 2>&1)"
is "the corrupted timestamp is replaced with a real one" "yes" \
   "$(awk -v s="$(cat "$HOME/.lidless_enabled_at" 2>/dev/null)" -v n="$(date +%s)" \
      'BEGIN { if (s !~ /^[0-9]+$/) { print "no"; exit } d = n - s; if (d < 0) d = -d; print (d < 60) ? "yes" : "no" }')"
rm -f "$HOME/.lidless_enabled_at"

# --- a valid stale timestamp is preserved for an already-active session ----
# caffeinate is pre-seeded as already running throughout this whole matrix
# (session_was_caffeinated=1), so is_new_session is never true here — this is
# exactly the "repeated on() while already active" case that must NOT reset
# a perfectly good timestamp. (The opposite case — a genuinely new session
# discarding a stale-but-valid one — is covered directly and exhaustively by
# is_new_session's own unit tests above; reaching it through on() itself
# would require is_caffeinated to report false, which takes the real,
# unshimmed `nohup caffeinate` branch this whole matrix deliberately avoids.)
echo 0 > "$ON_PMSET_STATE"
OLD_ENABLED_AT=$(( $(date +%s) - 99999 ))
echo "$OLD_ENABLED_AT" > "$HOME/.lidless_enabled_at"
on </dev/null >/dev/null 2>&1
is "an already-active session's valid timestamp is left untouched" "$OLD_ENABLED_AT" \
   "$(cat "$HOME/.lidless_enabled_at" 2>/dev/null)"
rm -f "$HOME/.lidless_enabled_at"

# --- a failed first attempt, then a successful retry, still gets a fresh
# timestamp — not the stale one from before either call ------------------
# review round 12 caught that discarding the stale timestamp only at
# the very end of on() (right before the write) meant a failed FIRST attempt
# — which starts caffeinate but then returns 1 early on a lid failure,
# deliberately leaving that caffeinate running for safety — left the stale
# file untouched. A RETRY would then see caffeinate already running (from the
# failed attempt), so is_new_session would report "not new", wrongly
# preserving the stale timestamp across what the user experiences as one
# session that just needed two tries. Fixed by discarding the stale file
# immediately once initial_lid is known, before the lid step that can fail
# and return early — this test drives both calls for real (using
# tests/bin/caffeinate, a harmless `sleep`, so on()'s real nohup-caffeinate
# branch can actually run without touching the machine's real sleep
# behavior).
rm -f "$HOME/.lidless_caffeinate_pid"
export FAKE_PS_COMM=""   # is_caffeinated() sees no existing process yet
export FAKE_CAFFEINATE_DURATION=2
STALE_ENABLED_AT=$(( $(date +%s) - 99999 ))
echo "$STALE_ENABLED_AT" > "$HOME/.lidless_enabled_at"
echo 0 > "$ON_PMSET_STATE"
export FAKE_SUDO_DENY=1   # first attempt: lid step fails outright
on </dev/null >/dev/null 2>&1
is "first (failed) attempt still discards the stale timestamp" "absent" \
   "$( [ -f "$HOME/.lidless_enabled_at" ] && echo present || echo absent )"

export FAKE_PS_COMM="caffeinate"   # retry: the failed attempt's caffeinate is now "running"
export FAKE_SUDO_DENY=0            # retry: lid step succeeds this time
export FAKE_SUDO_PMSET_STATE="$ON_PMSET_STATE"
ON_OUT="$(on </dev/null 2>&1)"
mentions "the retry succeeds" "Lidless is ON" "$ON_OUT"
is "and the retry writes a fresh timestamp, not the original stale one" "yes" \
   "$(awk -v s="$(cat "$HOME/.lidless_enabled_at" 2>/dev/null)" -v n="$(date +%s)" \
      'BEGIN { if (s !~ /^[0-9]+$/) { print "no"; exit } d = n - s; if (d < 0) d = -d; print (d < 60) ? "yes" : "no" }')"
# Real bash processes were started (our fake caffeinate) — clean them up.
kill "$(cat "$HOME/.lidless_caffeinate_pid" 2>/dev/null)" 2>/dev/null || true
unset FAKE_SUDO_DENY FAKE_CAFFEINATE_DURATION
rm -f "$HOME/.lidless_enabled_at"

unset FAKE_PMSET_CUSTOM FAKE_PMSET_PS FAKE_SUDO_PMSET_STATE
rm -f "$HOME/.lidless_caffeinate_pid"
unset FAKE_PMSET_G_STATE FAKE_SUDO_LOG FAKE_PS_COMM FAKE_DEFAULTS

# ---------------------------------------------------------------------------
section "status(): ignored/normal/unknown headline matrix"
# ---------------------------------------------------------------------------

STATUS_PMSET_STATE="$TMP/status-pmset-state"
export FAKE_PMSET_G_STATE="$STATUS_PMSET_STATE"

echo 1 > "$STATUS_PMSET_STATE"
printf '12345' > "$HOME/.lidless_caffeinate_pid"
export FAKE_PS_COMM="caffeinate"
STATUS_OUT="$(status)"
is "ON when lid ignored and caffeinate running" "ON" "${STATUS_OUT%%$'\n'*}"

export FAKE_PS_COMM=""
rm -f "$HOME/.lidless_caffeinate_pid"
echo 0 > "$STATUS_PMSET_STATE"
STATUS_OUT="$(status)"
is "OFF when lid normal and caffeinate not running" "OFF" "${STATUS_OUT%%$'\n'*}"

printf '0:1' > "$HOME/.lidless_lowpower_prev"
STATUS_OUT="$(status)"
is "OFF reports a pending auxiliary restore honestly" "OFF — RESTORE PENDING" \
   "${STATUS_OUT%%$'\n'*}"
rm -f "$HOME/.lidless_lowpower_prev"

printf '12345' > "$HOME/.lidless_caffeinate_pid"
export FAKE_PS_COMM="caffeinate"
echo 0 > "$STATUS_PMSET_STATE"
STATUS_OUT="$(status)"
is "PARTIAL when caffeinate running but lid normal" "PARTIAL" "${STATUS_OUT%%$'\n'*}"
export FAKE_PS_COMM=""
rm -f "$HOME/.lidless_caffeinate_pid"

unset FAKE_PMSET_G_STATE
export FAKE_PMSET_FAIL=1
STATUS_OUT="$(status)"
is "UNKNOWN headline when the lid probe is unreadable, not a confident ON/OFF/PARTIAL" \
   "UNKNOWN — could not read the current lid setting" "${STATUS_OUT%%$'\n'*}"
unset FAKE_PMSET_FAIL

# README promises status prints what EVERY setting resolves to, and then lists
# these two in the shared-keys table — but status() printed only the six it can
# act on, so the two settings that decide whether the screen goes dark were the
# ones you could not check from a terminal.
echo 0 > "$STATUS_PMSET_STATE"
export FAKE_PMSET_G_STATE="$STATUS_PMSET_STATE"
export FAKE_DEFAULTS="$TMP/defaults-status-panel"
printf 'blackoutBuiltinDisplayV1 1\npanelModeV1 dim\n' > "$FAKE_DEFAULTS"
load_settings
STATUS_OUT="$(status)"
mentions "status prints the panel blackout setting" \
   "panel blackout:         yes (app only)" "$STATUS_OUT"
mentions "status prints the panel mode, resolved the way the app resolves it" \
   "panel blackout mode:    dim (app only)" "$STATUS_OUT"
# Marked app-only rather than silently listed among the six: the script reports
# these, it can never act on them (see off()).
mentions "both are marked app-only, so nobody expects the script to act on them" \
   "(app only)" "$STATUS_OUT"

# --- what status() could not see: pending shutdown, session, panel, permission ---
# README claims the script "does the same thing without the GUI, with one
# exception". These four were four more.
echo 1 > "$STATUS_PMSET_STATE"
export FAKE_DEFAULTS="$TMP/defaults-status-parity"
printf 'automaticShutdownAfterHoursV1 4\n' > "$FAKE_DEFAULTS"
load_settings

printf '%s\n' "$(( $(date +%s) + 45 ))" > "$HOME/.lidless_shutdown_pending"
STATUS_OUT="$(status)"
mentions "status announces a pending automatic shutdown" \
   "AUTOMATIC SHUTDOWN PENDING" "$STATUS_OUT"
mentions "and names the command that stops it" "cancel-shutdown" "$STATUS_OUT"
printf '%s\n' "$(( $(date +%s) - 5 ))" > "$HOME/.lidless_shutdown_pending"
mentions "an expired deadline says the power-off is already being requested" \
   "grace period has expired" "$(status)"
printf 'not-an-epoch\n' > "$HOME/.lidless_shutdown_pending"
mentions "an unreadable deadline still reports the pending shutdown" \
   "deadline unreadable" "$(status)"
rm -f "$HOME/.lidless_shutdown_pending"
lacks "and nothing is claimed when no shutdown is pending" \
   "SHUTDOWN PENDING" "$(status)"

# 1h 59m 30s ago, not exactly 2h: an exact boundary flips both printed values
# when a second ticks between this write and status()'s own `date +%s` — that
# raced once in a real run. Mid-minute gives 30 s of slack in both directions.
echo $(( $(date +%s) - 2 * 3600 + 30 )) > "$HOME/.lidless_enabled_at"
STATUS_OUT="$(status)"
mentions "status reports how long the session has been up" "session: 1h 59m" "$STATUS_OUT"
mentions "and how long the hours limit leaves it" "shutdown limit in 2h 0m" "$STATUS_OUT"
echo $(( $(date +%s) - 6 * 3600 )) > "$HOME/.lidless_enabled_at"
mentions "a session past its limit says the watchdog will act" \
   "past the 4h limit" "$(status)"
rm -f "$HOME/.lidless_enabled_at"

# The blackout state, which only the app writes and only SSH may need to read.
printf '0.5' > "$HOME/.lidless_display_prev"
touch "$HOME/.lidless_display_heartbeat"
# Not asserted on the exact age: the second can tick over between the touch
# and the read, and it did — one failure in ten runs before this was pinned to
# the verdict instead of the number.
mentions "a live blackout is reported as held" \
   "a live Lidless is holding it" "$(status)"
touch -t "$(date -v-2M '+%Y%m%d%H%M')" "$HOME/.lidless_display_heartbeat"
STATUS_OUT="$(status)"
mentions "a stale heartbeat says the owner looks hung" "looks hung" "$STATUS_OUT"
mentions "and names the way out, which is the whole point over SSH" \
   "rescue-display" "$STATUS_OUT"
rm -f "$HOME/.lidless_display_heartbeat"
mentions "a marker with no heartbeat at all is reported too" \
   "no heartbeat" "$(status)"
rm -f "$HOME/.lidless_display_prev"
lacks "and a Mac with no blackout says nothing about the panel state" \
   "BLACKED OUT" "$(status)"

# The one-time permission, which the app gives a permanent card.
AUTOMATIC_SHUTDOWN_HELPER_VERSION_CHECK_PATH="$ROOT/tools/lidless-poweroff"
mentions "status reports the power permission as installed" \
   "power permission: installed" "$(status)"
AUTOMATIC_SHUTDOWN_HELPER_VERSION_CHECK_PATH="$TMP/no-such-helper"
AUTOMATIC_SHUTDOWN_HELPER="$TMP/no-such-helper"
mentions "and as missing when it is not there" \
   "power permission: not installed" "$(status)"
printf '%s\n' '#!/bin/bash' 'LIDLESS_POWEROFF_VERSION="1"' > "$TMP/outdated-installed-helper"
AUTOMATIC_SHUTDOWN_HELPER_VERSION_CHECK_PATH="$TMP/outdated-installed-helper"
AUTOMATIC_SHUTDOWN_HELPER="$TMP/outdated-installed-helper"
mentions "an installed but outdated helper is called out, not called missing" \
   "OUTDATED helper" "$(status)"
AUTOMATIC_SHUTDOWN_HELPER_VERSION_CHECK_PATH="$ROOT/tools/lidless-poweroff"
AUTOMATIC_SHUTDOWN_HELPER="/Library/PrivilegedHelperTools/io.github.lidless.poweroff"


export FAKE_DEFAULTS="$TMP/no-such-domain"
load_settings
STATUS_OUT="$(status)"
mentions "with no domain at all they resolve to the app's own defaults, not blank" \
   "panel blackout:         no (app only)" "$STATUS_OUT"
mentions "...including the mode's default" \
   "panel blackout mode:    virtual (app only)" "$STATUS_OUT"
unset FAKE_DEFAULTS FAKE_PMSET_G_STATE
load_settings

# ---------------------------------------------------------------------------
section "the watchdog script, end to end"
# ---------------------------------------------------------------------------
#
# tools/lidless-check.sh runs unattended from a LaunchAgent, so it is worth
# driving the whole thing rather than only its arithmetic. Every command it
# reaches for is faked: `sudo` records instead of elevating, `pgrep` reports no
# processes so a real caffeinate on this machine can never be killed, and
# `osascript` swallows the notifications.
#
# FAKE_PS_COMM is left empty throughout, so `off` never reaches its `kill` — the
# pid in a sandbox pid file could belong to something real.

CHECK="$ROOT/tools/lidless-check.sh"

# run_watchdog <name> — sets WD_OUT and WD_SUDO from a single run
run_watchdog() {
  export FAKE_SUDO_LOG="$TMP/sudo.log"
  export FAKE_OSASCRIPT_LOG="$TMP/osascript.log"
  : > "$FAKE_SUDO_LOG"
  : > "$FAKE_OSASCRIPT_LOG"
  # </dev/null: the watchdog always runs unattended in production (a
  # LaunchAgent has no terminal), and have_tty()'s `[ -t 0 ]` must see that
  # here too, regardless of whether tests/run.sh itself happens to be run
  # from an interactive shell — otherwise FAKE_SUDO_DENY/FAKE_SUDO_DENY_MATCH
  # silently stop applying (they only gate the `-n` invocation shape). review
  #  round 2 caught the same gap in the direct off() tests below;
  # this closes it here too.
  WD_OUT="$(HOME="$HOME" PATH="$PATH" bash "$CHECK" < /dev/null 2>&1)"
  WD_SUDO="$(cat "$FAKE_SUDO_LOG")"
}

export FAKE_PS_COMM=""
export FAKE_PGREP_OUT=""
export FAKE_PMSET_CUSTOM="$MACBOOK"
export FAKE_PMSET_PS="$FIXTURES/pmset-ps-ac.txt"
export FAKE_DEFAULTS="$TMP/wd-defaults"
export FAKE_SUDO_DENY=0
export AUTOMATIC_SHUTDOWN_GRACE_SECONDS=0
export AUTOMATIC_SHUTDOWN_HELPER_VERSION_CHECK_PATH="$ROOT/tools/lidless-poweroff"
rm -f "$HOME/.lidless_caffeinate_pid" "$HOME/.lidless_lowpower_prev"

# --- lid already normal: stays silent -------------------------------------
export FAKE_PMSET_G="$FIXTURES/pmset-g-sleepdisabled-off.txt"
printf 'automaticShutdownAfterHoursV1 1\n' > "$FAKE_DEFAULTS"
run_watchdog
is "silent when Lidless is off" "" "$WD_OUT"
is "and touches nothing"            "" "$WD_SUDO"

# --- lid ignored, limits not reached: warns only --------------------------
export FAKE_PMSET_G="$FIXTURES/pmset-g-sleepdisabled-on.txt"
printf 'automaticShutdownAfterHoursV1 8\n' > "$FAKE_DEFAULTS"
date +%s > "$HOME/.lidless_enabled_at"
run_watchdog
mentions "warns when the lid setting is orphaned" "warned:" "$WD_OUT"
is "but does not turn anything off" "" "$WD_SUDO"

# --- probe unreadable, tracked session, limit not reached: logs only --------
# Unknown does not force an off from one ambiguous sample, but the timestamp
# from the preceding case is session evidence and allows deadline evaluation.
export FAKE_PMSET_FAIL=1
run_watchdog
mentions "logs that the probe was unreadable" "probe unreadable" "$WD_OUT"
is "and touches nothing" "" "$WD_SUDO"
is "and does not notify either" "" "$(cat "$FAKE_OSASCRIPT_LOG")"

# Unknown with no tracked Lidless session must not treat a global low-battery
# preference as permission to change system state.
rm -f "$HOME/.lidless_enabled_at" "$HOME/.lidless_caffeinate_pid"
printf 'automaticShutdownBelowBatteryPercentV1 20\n' > "$FAKE_DEFAULTS"
export FAKE_PMSET_PS="$FIXTURES/pmset-ps-battery.txt"
run_watchdog
is "unknown without session evidence does not trigger automatic shutdown" "0" \
   "$(printf '%s' "$WD_OUT" | grep -c 'automatic shutdown triggered' || true)"
is "and still does not invoke sudo" "" "$WD_SUDO"
export FAKE_PMSET_PS="$FIXTURES/pmset-ps-ac.txt"
unset FAKE_PMSET_FAIL

# From here on, off() re-reads SleepDisabled after attempting a restore
# instead of trusting pmset's exit status (docs/ARCHITECTURE.md's rule,
# extended from sysadminctl to pmset — success is decided by re-reading the
# value). The static FAKE_PMSET_G fixture cannot reflect that a restore
# "took", so `-g` is backed by a small state file from here on, kept in step
# by tests/bin/sudo whenever it sees a `pmset -a disablesleep N` it would
# have actually run.
PMSET_STATE="$TMP/pmset-sleepdisabled-state"
export FAKE_PMSET_G_STATE="$PMSET_STATE"
export FAKE_SUDO_PMSET_STATE="$PMSET_STATE"

# --- unknown probe + tracked expired session: fail-safe shutdown -----------
# A malformed value produces the tri-state `unknown`; the fake installed
# helper then restores the lid state and accepts the shutdown request.
echo 7 > "$PMSET_STATE"
printf 'automaticShutdownAfterHoursV1 4\n' > "$FAKE_DEFAULTS"
echo $(( $(date +%s) - 6 * 3600 )) > "$HOME/.lidless_enabled_at"
run_watchdog
mentions "unknown still evaluates a due configured limit" "probe unreadable" "$WD_OUT"
mentions "and triggers the expired limit" "automatic shutdown triggered" "$WD_OUT"
mentions "and requests a real system halt" "automatic shutdown requested" "$WD_OUT"
mentions "and invokes the fixed power-off helper" "/Library/PrivilegedHelperTools/io.github.lidless.poweroff" "$WD_SUDO"
is "the formerly unknown lid state is now confirmed normal" "0" "$(cat "$PMSET_STATE")"

# --- limit exceeded, helper installed: powers off silently ----------------
echo 1 > "$PMSET_STATE"   # starts ignored
printf 'automaticShutdownAfterHoursV1 4\n' > "$FAKE_DEFAULTS"
echo $(( $(date +%s) - 6 * 3600 )) > "$HOME/.lidless_enabled_at"
run_watchdog
mentions "automatic shutdown fires past the hours limit" "automatic shutdown triggered" "$WD_OUT"
mentions "and reports the reason" "on for 6h (limit 4h)" "$WD_OUT"
mentions "and requests shutdown" "automatic shutdown requested" "$WD_OUT"
mentions "the root-owned helper is what it ran" "/Library/PrivilegedHelperTools/io.github.lidless.poweroff" "$WD_SUDO"
# The whole safety argument for the watchdog: with no terminal it must use
# sudo -n, so it can never sit waiting on a password prompt nobody can see.
mentions "and it used sudo -n, never an interactive sudo" \
         "-n /Library/PrivilegedHelperTools/io.github.lidless.poweroff" "$WD_SUDO"
is "the enabled-at stamp is cleared" "absent" \
   "$( [ -f "$HOME/.lidless_enabled_at" ] && echo present || echo absent )"
is "and SleepDisabled actually reads back as restored" "0" "$(cat "$PMSET_STATE")"

# --- limit exceeded, no sudoers rule: fails loudly, changes nothing -------
export FAKE_SUDO_DENY=1
echo 1 > "$PMSET_STATE"
echo $(( $(date +%s) - 6 * 3600 )) > "$HOME/.lidless_enabled_at"
run_watchdog
mentions "reports failure when sudo -n is refused" "automatic shutdown FAILED" "$WD_OUT"
mentions "and says so in a notification" "Automatic shutdown failed" "$(cat "$FAKE_OSASCRIPT_LOG")"
is "the stamp is kept so the next run retries" "present" \
   "$( [ -f "$HOME/.lidless_enabled_at" ] && echo present || echo absent )"
is "and nothing was actually restored" "1" "$(cat "$PMSET_STATE")"
export FAKE_SUDO_DENY=0

# --- limit exceeded, but the kernel rejects the shutdown request -----------
export FAKE_POWEROFF_REQUEST_FAIL=1
echo 1 > "$PMSET_STATE"
echo $(( $(date +%s) - 6 * 3600 )) > "$HOME/.lidless_enabled_at"
run_watchdog
mentions "reports failure when the shutdown request is rejected" \
         "automatic shutdown FAILED" "$WD_OUT"
is "and the stamp is kept so the next run retries" "present" \
   "$( [ -f "$HOME/.lidless_enabled_at" ] && echo present || echo absent )"
unset FAKE_POWEROFF_REQUEST_FAIL

# --- Low Power Mode is restored before automatic shutdown ------------------
echo 1 > "$PMSET_STATE"
printf 'automaticShutdownAfterHoursV1 4\n' > "$FAKE_DEFAULTS"
echo $(( $(date +%s) - 6 * 3600 )) > "$HOME/.lidless_enabled_at"
printf '0:1' > "$HOME/.lidless_lowpower_prev"
run_watchdog
mentions "shutdown is requested after restoring Low Power Mode" \
         "automatic shutdown requested" "$WD_OUT"
mentions "restores the saved AC Low Power Mode value" \
         "-n pmset -c lowpowermode 0" "$WD_SUDO"
mentions "restores the saved battery Low Power Mode value" \
         "-n pmset -b lowpowermode 1" "$WD_SUDO"
is "the consumed Low Power Mode restore point is removed" "absent" \
   "$( [ -f "$HOME/.lidless_lowpower_prev" ] && echo present || echo absent )"

# --- an unrestored screen lock blocks unattended shutdown -----------------
echo 1 > "$PMSET_STATE"
printf 'automaticShutdownAfterHoursV1 4\n' > "$FAKE_DEFAULTS"
echo $(( $(date +%s) - 6 * 3600 )) > "$HOME/.lidless_enabled_at"
printf '300' > "$HOME/.lidless_screenlock_prev"
run_watchdog
mentions "screen-lock restore requirement cancels shutdown" \
         "screen lock needs an interactive restore" "$WD_OUT"
is "the fixed power-off helper is not invoked while screen lock is relaxed" "0" \
   "$(printf '%s' "$WD_SUDO" | grep -c 'io.github.lidless.poweroff' || true)"
rm -f "$HOME/.lidless_screenlock_prev"

# --- grace period can be cancelled without taking the operation lock -------
echo 1 > "$PMSET_STATE"
printf 'automaticShutdownAfterHoursV1 4\n' > "$FAKE_DEFAULTS"
echo $(( $(date +%s) - 6 * 3600 )) > "$HOME/.lidless_enabled_at"
export AUTOMATIC_SHUTDOWN_GRACE_SECONDS=1
(
  for _ in $(seq 1 100); do
    if [ -f "$HOME/.lidless_shutdown_pending" ]; then
      printf 'cancel\n' > "$HOME/.lidless_shutdown_cancel"
      exit 0
    fi
    sleep 0.01
  done
  exit 1
) &
CANCEL_WRITER_PID=$!
run_watchdog
wait "$CANCEL_WRITER_PID"
mentions "shutdown can be cancelled during the grace period" \
         "automatic shutdown cancelled during grace period" "$WD_OUT"
is "cancelled shutdown never invokes the helper" "0" \
   "$(printf '%s' "$WD_SUDO" | grep -c 'io.github.lidless.poweroff' || true)"
export AUTOMATIC_SHUTDOWN_GRACE_SECONDS=0

# --- the trigger is re-evaluated at the end of the grace period ------------
# The grace period exists so a human can react, and the obvious reaction to
# "battery at 12%" is to plug in. That used to change nothing: the only thing
# consulted after the sleep was the cancel file, so the Mac powered off on
# mains at a rising charge. FAKE_PMSET_PS points at a file the writer below
# rewrites mid-grace, which is exactly a charger going in.
echo 1 > "$PMSET_STATE"
printf 'automaticShutdownBelowBatteryPercentV1 20\n' > "$FAKE_DEFAULTS"
date +%s > "$HOME/.lidless_enabled_at"
WD_LIVE_PS="$TMP/pmset-ps-live.txt"
cp "$FIXTURES/pmset-ps-battery.txt" "$WD_LIVE_PS"
export FAKE_PMSET_PS="$WD_LIVE_PS"
export AUTOMATIC_SHUTDOWN_GRACE_SECONDS=1
(
  for _ in $(seq 1 100); do
    if [ -f "$HOME/.lidless_shutdown_pending" ]; then
      cp "$FIXTURES/pmset-ps-ac.txt" "$WD_LIVE_PS"
      exit 0
    fi
    sleep 0.01
  done
  exit 1
) &
WD_PLUG_PID=$!
run_watchdog
wait "$WD_PLUG_PID"
mentions "a charger plugged in during the grace abandons the shutdown" \
         "automatic shutdown abandoned" "$WD_OUT"
mentions "and the reason it was armed for is named" "battery at 18%" "$WD_OUT"
is "an abandoned shutdown never invokes the helper" "0" \
   "$(printf '%s' "$WD_SUDO" | grep -c 'io.github.lidless.poweroff' || true)"
is "and the pending marker is cleared, so the app and CLI agree" "absent" \
   "$( [ -f "$HOME/.lidless_shutdown_pending" ] && echo present || echo absent )"
mentions "and the user is told, having been warned a minute earlier" \
         "Automatic shutdown abandoned" "$(cat "$FAKE_OSASCRIPT_LOG")"

# The same re-check must not talk anyone out of a shutdown that IS still due.
cp "$FIXTURES/pmset-ps-battery.txt" "$WD_LIVE_PS"
echo 1 > "$PMSET_STATE"
date +%s > "$HOME/.lidless_enabled_at"
run_watchdog
mentions "a condition that still holds after the grace still shuts down" \
         "automatic shutdown requested" "$WD_OUT"
export AUTOMATIC_SHUTDOWN_GRACE_SECONDS=0
unset FAKE_PMSET_PS
printf 'automaticShutdownAfterHoursV1 4\n' > "$FAKE_DEFAULTS"

# --- limit exceeded, but the lock is held by another Lidless process ------
# with_lock's exit-code-75 branch (lockf's EX_TEMPFAIL, propagated) — review
#  round 2 caught this was never exercised end to end.
echo 1 > "$PMSET_STATE"
echo $(( $(date +%s) - 6 * 3600 )) > "$HOME/.lidless_enabled_at"
WD_LOCK_READY="$TMP/wd-lock-holder-ready"
WD_LOCK_RELEASE="$TMP/wd-lock-holder-release"
rm -f "$WD_LOCK_READY" "$WD_LOCK_RELEASE"
bash -c '
  source "'"$ROOT"'/lidless.sh"
  exec 9>>"$LOCK_FILE"
  /usr/bin/lockf -t 0 9
  : > "'"$WD_LOCK_READY"'"
  while [ ! -f "'"$WD_LOCK_RELEASE"'" ]; do
    sleep 0.05
  done
' &
WD_LOCK_HOLDER_PID=$!
WD_LOCK_HELD=0
for _ in $(seq 1 100); do
  [ -f "$WD_LOCK_READY" ] && { WD_LOCK_HELD=1; break; }
  sleep 0.02
done
if [ "$WD_LOCK_HELD" = "1" ]; then
  run_watchdog
  mentions "logs a quiet deferred outcome, not a hard failure" "automatic shutdown deferred" "$WD_OUT"
  mentions "and the grace warning remains visible while the next tick retries" \
           "Mac will shut down" "$(cat "$FAKE_OSASCRIPT_LOG")"
else
  bad "watchdog lock holder never signaled ready — deferred-outcome test could not run"
fi
touch "$WD_LOCK_RELEASE"
wait "$WD_LOCK_HOLDER_PID"

# --- battery limit --------------------------------------------------------
export FAKE_PMSET_PS="$FIXTURES/pmset-ps-battery.txt"
echo 1 > "$PMSET_STATE"
printf 'automaticShutdownBelowBatteryPercentV1 20\n' > "$FAKE_DEFAULTS"
date +%s > "$HOME/.lidless_enabled_at"
run_watchdog
mentions "automatic shutdown fires below the battery limit" "battery at 18% (limit 20%)" "$WD_OUT"

# --- battery probe unreadable: does not act as if it were on AC -----------
# A failed `pmset -g ps` used to read as AC, silently disabling battery
# auto-off. See docs/ARCHITECTURE.md. Lid stays ignored
# (so the watchdog proceeds past its initial gate) and the hours limit stays
# unset, so only the battery branch of auto_off_reason is under test.
echo 1 > "$PMSET_STATE"
date +%s > "$HOME/.lidless_enabled_at"
printf 'automaticShutdownBelowBatteryPercentV1 20\n' > "$FAKE_DEFAULTS"
export FAKE_PMSET_FAIL_PS=1
run_watchdog
is "no shutdown reason fires from an unreadable power source" "0" \
   "$(printf '%s' "$WD_OUT" | grep -c 'automatic shutdown triggered' || true)"
unset FAKE_PMSET_FAIL_PS
export FAKE_PMSET_PS="$FIXTURES/pmset-ps-battery.txt"

unset FAKE_PMSET_G_STATE FAKE_SUDO_PMSET_STATE

# --- future enabled-at timestamp: repaired, not left to suppress forever --
# See docs/ARCHITECTURE.md — mirrors Sources/main.swift's
# ensureEnabledAt rather than a shell-invented policy.
export FAKE_PMSET_G="$FIXTURES/pmset-g-sleepdisabled-on.txt"
printf 'automaticShutdownAfterHoursV1 4\n' > "$FAKE_DEFAULTS"
echo $(( $(date +%s) + 99999 )) > "$HOME/.lidless_enabled_at"
run_watchdog
mentions "logs the repair" "repaired a future" "$WD_OUT"
is "and does not fire the hours guard immediately after repairing" "0" \
   "$(printf '%s' "$WD_OUT" | grep -c 'automatic shutdown triggered' || true)"
is "the stamp now reads close to now, not the bogus future value" "yes" \
   "$(awk -v s="$(cat "$HOME/.lidless_enabled_at")" -v n="$(date +%s)" \
      'BEGIN { d = n - s; if (d < 0) d = -d; print (d < 60) ? "yes" : "no" }')"
rm -f "$HOME/.lidless_enabled_at"

# --- empty/malformed enabled-at: falls back to the pid file's mtime, not
# left to silently and permanently suppress the hours guard ----------------
# review round 10 caught that an existing-but-corrupt
# .lidless_enabled_at (e.g. left empty by a crash mid-write) was trusted
# based only on `-f` — is_plausible_epoch rejected the empty content, so the
# hours guard silently never fired again, and neither the watchdog nor a
# later on() ever repaired the file (on() only writes when it's entirely
# absent). Falls back to the pid file's mtime, same as the "file doesn't
# exist yet" case, and persists the repair.
printf '12345' > "$HOME/.lidless_caffeinate_pid"
: > "$HOME/.lidless_enabled_at"   # present, but empty — not a plausible epoch
printf 'automaticShutdownAfterHoursV1 4\n' > "$FAKE_DEFAULTS"
run_watchdog
mentions "logs the repair using the pid file's mtime" \
         "repaired an empty/malformed .lidless_enabled_at" "$WD_OUT"
is "the stamp is now close to now (the pid file was just created)" "yes" \
   "$(awk -v s="$(cat "$HOME/.lidless_enabled_at")" -v n="$(date +%s)" \
      'BEGIN { d = n - s; if (d < 0) d = -d; print (d < 60) ? "yes" : "no" }')"
is "and does not immediately fire a bogus auto-off" "0" \
   "$(printf '%s' "$WD_OUT" | grep -c 'automatic shutdown triggered' || true)"
rm -f "$HOME/.lidless_enabled_at" "$HOME/.lidless_caffeinate_pid"

# --- LIDLESS_SH wins, but a bad value still falls back ----------------
# Pointing it at a file that does not exist must not break a working install:
# the script keeps looking, and finds lidless.sh next to itself.
export FAKE_PMSET_G="$FIXTURES/pmset-g-sleepdisabled-off.txt"
WD_OUT="$(LIDLESS_SH=/nonexistent/lidless.sh bash "$CHECK" 2>&1)"
is "a bad LIDLESS_SH falls back to the sibling copy" "" "$WD_OUT"

# --- genuinely missing: reported, not silently ignored --------------------
# Copied somewhere with no lidless.sh anywhere near it, which is what a
# half-finished install looks like.
ORPHAN_DIR="$TMP/orphan-install"
mkdir -p "$ORPHAN_DIR" "$TMP/empty-home"
cp "$CHECK" "$ORPHAN_DIR/"
WD_OUT="$(HOME="$TMP/empty-home" bash "$ORPHAN_DIR/lidless-check.sh" 2>&1)" \
  && WD_RC=0 || WD_RC=$?
mentions "broken install is reported" "cannot find lidless.sh" "$WD_OUT"
is "and exits non-zero" "1" "$WD_RC"
mentions "and notifies, rather than failing invisibly" "watchdog broken" "$(cat "$FAKE_OSASCRIPT_LOG")"

rm -f "$HOME/.lidless_enabled_at"
unset FAKE_PMSET_G FAKE_PMSET_PS FAKE_PMSET_CUSTOM FAKE_DEFAULTS FAKE_PS_COMM \
      FAKE_PGREP_OUT FAKE_SUDO_LOG FAKE_SUDO_DENY FAKE_OSASCRIPT_LOG

# ---------------------------------------------------------------------------
section "state files from the old name are adopted"
# ---------------------------------------------------------------------------
#
# The tool was called "remote mode" and kept state in ~/.remote_mode_*. A session
# running across the rename must not be stranded: without this, `off` would see a
# clean slate, decide there was nothing to restore, and leave the Mac ignoring
# the lid with the saved Low Power Mode value gone.

LEGACY_HOME="$TMP/legacy-home"
mkdir -p "$LEGACY_HOME"
printf '4242'       > "$LEGACY_HOME/.remote_mode_caffeinate_pid"
printf '0:1'        > "$LEGACY_HOME/.remote_mode_lowpower_prev"
printf '900'        > "$LEGACY_HOME/.remote_mode_screenlock_prev"
printf '1700000000' > "$LEGACY_HOME/.remote_mode_enabled_at"

( export HOME="$LEGACY_HOME"; migrate_legacy_state )

is "pid adopted"          "4242"       "$(cat "$LEGACY_HOME/.lidless_caffeinate_pid" 2>/dev/null)"
is "low power adopted"    "0:1"        "$(cat "$LEGACY_HOME/.lidless_lowpower_prev" 2>/dev/null)"
is "screen lock adopted"  "900"        "$(cat "$LEGACY_HOME/.lidless_screenlock_prev" 2>/dev/null)"
is "enabled-at adopted"   "1700000000" "$(cat "$LEGACY_HOME/.lidless_enabled_at" 2>/dev/null)"
is "old pid file is gone" "absent" \
   "$( [ -e "$LEGACY_HOME/.remote_mode_caffeinate_pid" ] && echo present || echo absent )"

# A current file must win: adopting an older one over it would resurrect stale
# state and, for the low power value, restore the wrong setting.
BOTH_HOME="$TMP/both-home"
mkdir -p "$BOTH_HOME"
printf '1:1' > "$BOTH_HOME/.remote_mode_lowpower_prev"
printf '0:1' > "$BOTH_HOME/.lidless_lowpower_prev"
( export HOME="$BOTH_HOME"; migrate_legacy_state )
is "current file is not overwritten" "0:1" "$(cat "$BOTH_HOME/.lidless_lowpower_prev")"
is "and the old one is left alone"   "1:1" "$(cat "$BOTH_HOME/.remote_mode_lowpower_prev")"

# Nothing to adopt must be a silent no-op, not an error.
EMPTY_HOME="$TMP/empty-migrate-home"
mkdir -p "$EMPTY_HOME"
succeeds "no legacy files is fine" bash -c '
  export HOME="'"$EMPTY_HOME"'"
  source "'"$ROOT"'/lidless.sh"
  migrate_legacy_state'
is "and creates nothing" "0" "$(ls -A "$EMPTY_HOME" | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
section "the app's parsers, on the same fixtures"
# ---------------------------------------------------------------------------
#
# The app and the script must agree about the same Mac, so the Swift parsers are
# checked against the identical fixture files. Skipped, loudly, where swiftc is
# not installed — the shell tests above still stand on their own.

if command -v swiftc >/dev/null 2>&1; then
  SWIFT_BIN="$TMP/parser-tests"
  if swiftc -parse-as-library -o "$SWIFT_BIN" \
       "$ROOT/Sources/SystemProbe.swift" "$ROOT/Sources/SMCSensors.swift" \
       "$ROOT/tests/swift/ParserTests.swift" \
       2>"$TMP/swiftc.log"; then
    SWIFT_OUT="$("$SWIFT_BIN" "$FIXTURES" 2>&1)"
    SWIFT_RC=$?
    # Reprint the child's lines indented, and fold its tally into ours.
    printf '%s\n' "$SWIFT_OUT" | sed -n 's/^  /  /p' | grep -E '^  (ok|FAIL)' \
      | while IFS= read -r line; do printf '%s\n' "$line"; done
    SWIFT_PASS=$(printf '%s\n' "$SWIFT_OUT" | grep -cE '^  ok ')
    SWIFT_FAIL=$(printf '%s\n' "$SWIFT_OUT" | grep -cE '^  FAIL')
    PASS=$((PASS + SWIFT_PASS))
    FAIL=$((FAIL + SWIFT_FAIL))
    if [ "$SWIFT_RC" -ne 0 ] && [ "$SWIFT_FAIL" -eq 0 ]; then
      bad "swift parser tests exited $SWIFT_RC without reporting a failure"
    fi
  else
    bad "swiftc could not build the parser tests"
    sed 's/^/       /' "$TMP/swiftc.log"
  fi
else
  printf '  %sskip%s swiftc not installed — app parsers not checked\n' "$D" "$N"
fi

# ---------------------------------------------------------------------------
section "with_lock interop: shell lockf <-> Swift native flock() (Phase 4)"
# ---------------------------------------------------------------------------
#
# The lockf<->lockf tests above and ParserTests.swift's flock<->flock test
# each prove one side is internally consistent, but neither proves the two
# sides see each other's lock — which is the actual Phase 4 DoD. This drives
# both directions for real, using tests/swift/LockHelper.swift as a second
# process (flock(2) is per-open-file-description, so two opens in one process
# cannot exercise cross-process behavior at all).

if command -v swiftc >/dev/null 2>&1; then
  LOCK_HELPER_BIN="$TMP/lock-helper"
  if swiftc -parse-as-library -o "$LOCK_HELPER_BIN" \
       "$ROOT/Sources/SystemProbe.swift" "$ROOT/tests/swift/LockHelper.swift" \
       2>"$TMP/lockhelper-swiftc.log"; then
    INTEROP_LOCK="$TMP/interop-lock"

    # --- shell holds via lockf, Swift's acquireLock refuses --------------
    # Readiness handshake here too — an earlier version slept a fixed 0.15s
    # and hoped the holder had acquired by then, which was flaky (occasional
    # false pass when the subshell was slow to start).
    # The holder holds until the contender has FINISHED its attempt, not for a
    # guessed interval. It used to `sleep 0.4` after signalling ready, which
    # meant the whole test rested on the parent noticing readiness (20 ms
    # granularity) AND spawning a Swift binary AND that binary opening the file
    # and calling flock, all inside 400 ms. Process spawn on a loaded machine
    # blows through that easily, the lock frees early, `acquire` succeeds and the
    # assertion fails — measured at roughly one run in three while the machine
    # was busy and one in four while it was idle, which is the signature of a
    # timing assumption rather than a bug in what is under test.
    HOLDER_READY="$TMP/lock-holder-ready"
    HOLDER_RELEASE="$TMP/lock-holder-release"
    rm -f "$HOLDER_READY" "$HOLDER_RELEASE"
    bash -c '
      source "'"$ROOT"'/lidless.sh"
      exec 9>>"'"$INTEROP_LOCK"'"
      /usr/bin/lockf -t 0 9
      : > "'"$HOLDER_READY"'"
      # Capped at ~10 s so a parent that died cannot leave this holding forever.
      for _ in $(seq 1 500); do
        [ -f "'"$HOLDER_RELEASE"'" ] && break
        sleep 0.02
      done
    ' &
    HOLDER_PID=$!
    HOLDER_HELD=0
    for _ in $(seq 1 100); do
      [ -f "$HOLDER_READY" ] && { HOLDER_HELD=1; break; }
      sleep 0.02
    done
    if [ "$HOLDER_HELD" = "1" ]; then
      if "$LOCK_HELPER_BIN" acquire "$INTEROP_LOCK"; then
        bad "Swift acquireLock refuses while shell holds the lock via lockf"
      else
        ok "Swift acquireLock refuses while shell holds the lock via lockf"
      fi
    else
      bad "shell holder never signaled ready — interop test could not run"
    fi
    # Released only now, after the attempt above has returned its verdict.
    : > "$HOLDER_RELEASE"
    wait "$HOLDER_PID"

    # --- Swift holds via native flock(), shell's with_lock refuses -------
    HELPER_OUT="$TMP/lock-helper.out"
    : > "$HELPER_OUT"
    # Same hazard from the other side, same fix: hold long enough that the
    # window cannot expire mid-attempt, and end it explicitly once the attempt
    # is done rather than waiting out a guess.
    "$LOCK_HELPER_BIN" hold "$INTEROP_LOCK" 10 > "$HELPER_OUT" &
    HELPER_PID=$!
    # Readiness handshake, not a blind sleep-then-hope: wait for "held" so
    # this cannot race Swift's own acquisition.
    HELD=0
    for _ in $(seq 1 100); do
      if grep -q '^held$' "$HELPER_OUT" 2>/dev/null; then HELD=1; break; fi
      sleep 0.02
    done
    if [ "$HELD" = "1" ]; then
      fails "shell with_lock refuses while Swift holds the lock via native flock()" bash -c '
        source "'"$ROOT"'/lidless.sh"
        LOCK_FILE="'"$INTEROP_LOCK"'"
        with_lock true
      '
    else
      bad "Swift LockHelper never reported \"held\" — interop test could not run"
    fi
    # The lock is released when this process exits, so `wait` returning is the
    # guarantee the next assertion needs.
    kill "$HELPER_PID" 2>/dev/null
    wait "$HELPER_PID" 2>/dev/null || true

    succeeds "shell with_lock acquires again once Swift released it" bash -c '
      source "'"$ROOT"'/lidless.sh"
      LOCK_FILE="'"$INTEROP_LOCK"'"
      with_lock true
    '
  else
    bad "swiftc could not build the lock interop helper"
    sed 's/^/       /' "$TMP/lockhelper-swiftc.log"
  fi
else
  printf '  %sskip%s swiftc not installed — lock interop not checked\n' "$D" "$N"
fi

# ---------------------------------------------------------------------------
section "the recovery tool (lidless-display-rescue), driven directly — Phase 1 of docs/ARCHITECTURE.md"
# ---------------------------------------------------------------------------
#
# The tool's main path performs a real display sweep — one was triggered by
# accident against this machine during the 2026-08-02 review (round 18,
# .claude/artifacts/self-review/gpt-5-6-sol/fixes-0802.md). Every case below
# uses --dry-run, which walks the same decision path without calling a single
# mutating CoreGraphics API, plus two env vars that exist only for this suite
# and do nothing in any real invocation:
#
#   LIDLESS_TEST_HOME                redirects the marker file. NSHomeDirectory()
#                                     ignores $HOME for a plain binary (verified:
#                                     HOME=/tmp/x still resolves to the real
#                                     home), so this is the only seam available —
#                                     the shell suite's own HOME-redirection
#                                     trick above does nothing for a compiled
#                                     Swift binary.
#   LIDLESS_TEST_FORCE_BUILTIN_GONE  forces builtinIsBack() to false without
#                                     touching a display, for the two cases that
#                                     need the panel to read as not confirmed
#                                     back (r13, r18). This Mac's real built-in
#                                     is genuinely on while these tests run, and
#                                     there is no way to make it read otherwise
#                                     without actually disabling it — which is
#                                     the display-churn hazard this tool exists
#                                     to recover from (docs/ARCHITECTURE.md).
#
# `tests/bin/` shims do not apply to the compiled rescue binary itself — but
# `kill` is used directly below to manage the test's own background
# processes, and by this point in the file `enable -n kill` (top of this
# script) has disabled the builtin, so a bare `kill`/`kill -9` here would
# resolve through PATH to tests/bin/kill instead: a fake that never signals
# anything and rejects any flag argument outright (it only understands
# `kill <pid>`). Every kill in this section uses /bin/kill explicitly to
# reach the real syscall.

if command -v swiftc >/dev/null 2>&1; then
  RESCUE_BIN="$TMP/lidless-display-rescue"
  if swiftc -parse-as-library -o "$RESCUE_BIN" \
       "$ROOT/Sources/DisplayRescue.swift" "$ROOT/Sources/VirtualDisplay.swift" "$ROOT/Sources/SystemProbe.swift" \
       2>"$TMP/rescue-swiftc.log"; then

    RESCUE_HOME="$TMP/rescue-home"
    mkdir -p "$RESCUE_HOME"

    # A pid that definitely belongs to no live process: a real child, killed
    # and reaped immediately before use. The kernel handing this exact number
    # to a brand-new process in the window between here and the rescue tool's
    # own kill(pid, 0) check is possible in principle but not something this
    # suite can rule out from user space.
    make_dead_pid() {
      sleep 300 &
      local pid=$!
      /bin/kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      echo "$pid"
    }

    # Starts `--watch <owner> <heartbeat> --dry-run` in the background and
    # waits (up to 3s, polling every 25ms — the same handshake the app itself
    # uses against this tool, fixes-0802.md round 2) for the readiness file it
    # creates before touching anything. Sets $WATCH_PID / $WATCH_LOG.
    start_watch() {
      local heartbeat="$1" owner="$2" force_gone="${3:-}"
      WATCH_LOG="$TMP/watch-$owner-$RANDOM.log"
      if [ "$force_gone" = "1" ]; then
        LIDLESS_TEST_HOME="$RESCUE_HOME" LIDLESS_TEST_FORCE_BUILTIN_GONE=1 \
          "$RESCUE_BIN" --watch "$owner" "$heartbeat" --dry-run >"$WATCH_LOG" 2>&1 &
      else
        LIDLESS_TEST_HOME="$RESCUE_HOME" \
          "$RESCUE_BIN" --watch "$owner" "$heartbeat" --dry-run >"$WATCH_LOG" 2>&1 &
      fi
      WATCH_PID=$!
      disown "$WATCH_PID" 2>/dev/null
      local waited=0
      while [ ! -f "$heartbeat.ready" ] && [ "$waited" -lt 3000 ]; do
        sleep 0.025
        waited=$((waited + 25))
      done
    }

    # SIGTERM, then up to 2s to actually exit, then SIGKILL if it didn't — the
    # same escalation this project already uses to guarantee the rescue tool's
    # own termination (Sources/main.swift, fixes-0802.md round 5). /bin/kill,
    # not the bare builtin: `enable -n kill` (top of this script) disables the
    # builtin so lidless.sh's own kill calls reach tests/bin/kill's shim, and
    # that shim never signals anything for real and rejects -9/-0 outright —
    # a bare `kill` here hit the same shim, hung every `wait` on a process
    # that could never die, and stalled the whole suite one test after this
    # one passed. The shim's contract is deliberate (see its own header
    # comment) and must not change; this section works around it instead.
    stop_watch() {
      /bin/kill "$WATCH_PID" 2>/dev/null
      local waited=0
      while /bin/kill -0 "$WATCH_PID" 2>/dev/null && [ "$waited" -lt 2000 ]; do
        sleep 0.05
        waited=$((waited + 50))
      done
      /bin/kill -9 "$WATCH_PID" 2>/dev/null
      wait "$WATCH_PID" 2>/dev/null
    }

    # wait_for_log <pattern> <logfile> [timeout-ms]
    wait_for_log() {
      local pattern="$1" log="$2" timeout_ms="${3:-8000}" waited=0
      while ! grep -q "$pattern" "$log" 2>/dev/null && [ "$waited" -lt "$timeout_ms" ]; do
        sleep 0.1
        waited=$((waited + 100))
      done
    }

    # --- baseline: --explain still changes nothing --------------------------
    EXPLAIN_OUT="$(LIDLESS_TEST_HOME="$RESCUE_HOME" "$RESCUE_BIN" --explain 2>&1)"
    mentions "--explain reports support" "support=" "$EXPLAIN_OUT"
    mentions "--explain reports the display lists" "displays:" "$EXPLAIN_OUT"
    mentions "--explain reports the marker" "marker=" "$EXPLAIN_OUT"
    mentions "--explain reports its decision" "would:" "$EXPLAIN_OUT"

    # --- r14: readiness handshake --------------------------------------------
    HB_READY="$TMP/hb-ready"
    : > "$HB_READY"
    start_watch "$HB_READY" "$$"
    is "r14: --watch creates <heartbeat>.ready before it starts watching" "present" \
       "$( [ -f "$HB_READY.ready" ] && echo present || echo absent )"
    stop_watch

    # --- trigger correctness: live owner + fresh heartbeat does NOT fire ----
    HB_FRESH="$TMP/hb-fresh"
    : > "$HB_FRESH"
    start_watch "$HB_FRESH" "$$"
    sleep 6
    lacks "a live owner with a fresh heartbeat does not trigger" "triggered:" "$(cat "$WATCH_LOG")"
    stop_watch

    # --- the kill(pid, 0) path: a dead owner triggers ------------------------
    HB_DEAD="$TMP/hb-dead"
    : > "$HB_DEAD"
    DEAD_PID_1="$(make_dead_pid)"
    start_watch "$HB_DEAD" "$DEAD_PID_1"
    wait_for_log "triggered:" "$WATCH_LOG"
    mentions "a dead owner pid triggers, even with a fresh heartbeat" \
      "triggered: ownerAlive=false" "$(cat "$WATCH_LOG")"
    stop_watch

    # --- stale-heartbeat path: live owner + backdated heartbeat triggers ----
    HB_STALE="$TMP/hb-stale"
    : > "$HB_STALE"
    touch -t "$(date -v-2H +%Y%m%d%H%M.%S)" "$HB_STALE"
    start_watch "$HB_STALE" "$$"
    wait_for_log "triggered:" "$WATCH_LOG"
    mentions "a live owner with a heartbeat stale past the threshold triggers" \
      "triggered: ownerAlive=true" "$(cat "$WATCH_LOG")"
    stop_watch

    # --- r17: a heartbeat dated in the FUTURE triggers, rather than reading
    # as fresh ----------------------------------------------------------------
    HB_FUTURE="$TMP/hb-future"
    : > "$HB_FUTURE"
    touch -t "$(date -v+2H +%Y%m%d%H%M.%S)" "$HB_FUTURE"
    start_watch "$HB_FUTURE" "$$"
    wait_for_log "triggered:" "$WATCH_LOG"
    mentions "r17: a heartbeat dated in the future triggers rather than reading as fresh" \
      "triggered: ownerAlive=true heartbeatAge=inf" "$(cat "$WATCH_LOG")"
    stop_watch

    # --- the infinite-age contract adoptStrandedPanel relies on --------------
    HB_MISSING="$TMP/hb-missing"
    rm -f "$HB_MISSING"
    start_watch "$HB_MISSING" "$$"
    wait_for_log "triggered:" "$WATCH_LOG"
    mentions "a missing heartbeat file triggers (infinite age)" \
      "triggered: ownerAlive=true heartbeatAge=inf" "$(cat "$WATCH_LOG")"
    stop_watch

    # --- r18: three failed supervised sweeps go back to watching, not exit --
    HB_R18="$TMP/hb-r18"
    : > "$HB_R18"
    DEAD_PID_2="$(make_dead_pid)"
    start_watch "$HB_R18" "$DEAD_PID_2" "1"
    wait_for_log "no luck after 3 supervised sweeps" "$WATCH_LOG" 25000
    mentions "r18: three failed supervised sweeps wait and resume watching, not exit" \
      "no luck after 3 supervised sweeps; waiting 60s before watching again" "$(cat "$WATCH_LOG")"
    is "r18: the watchdog process is still running after giving up on this round" "running" \
       "$( /bin/kill -0 "$WATCH_PID" 2>/dev/null && echo running || echo gone )"
    stop_watch

    # --- r13: marker kept when the built-in is not confirmed back -----------
    RESCUE_MARKER_HOME="$TMP/rescue-marker-home"
    mkdir -p "$RESCUE_MARKER_HOME"
    printf '0.5' > "$RESCUE_MARKER_HOME/.lidless_display_prev"
    # Both halves forced. Leaving "something is visible" to the live machine made
    # this fail whenever the display domain happened to be asleep — see
    # DisplayRescue.somethingIsVisible().
    MARKER_DRY_OUT="$(LIDLESS_TEST_HOME="$RESCUE_MARKER_HOME" LIDLESS_TEST_FORCE_BUILTIN_GONE=1 \
      LIDLESS_TEST_FORCE_VISIBLE=1 \
      "$RESCUE_BIN" --dry-run 2>&1)"
    mentions "r13: marker kept when something is visible but the built-in is not confirmed back" \
      "decision: would-keep-marker" "$MARKER_DRY_OUT"
    is "r13: --dry-run never deletes the marker file" "present" \
       "$( [ -f "$RESCUE_MARKER_HOME/.lidless_display_prev" ] && echo present || echo absent )"

    # --- existing convention: bad usage still exits 64 -----------------------
    "$RESCUE_BIN" --watch not-a-pid /tmp/whatever-heartbeat >/dev/null 2>&1
    is "bad --watch usage (non-numeric pid) exits 64" "64" "$?"

  else
    bad "swiftc could not build lidless-display-rescue"
    sed 's/^/       /' "$TMP/rescue-swiftc.log"
  fi
else
  printf '  %sskip%s swiftc not installed — recovery tool not checked\n' "$D" "$N"
fi

# ---------------------------------------------------------------------------
section "cancel-shutdown answers, whether or not anything was pending"
# ---------------------------------------------------------------------------
#
# The command people run seconds after a shutdown warning. It used to return 1
# and print nothing when no shutdown was pending, which is indistinguishable
# from a typo — and from success.

CANCEL_HOME="$TMP/cancel-home"
mkdir -p "$CANCEL_HOME"

CANCEL_OUT="$(
  HOME="$CANCEL_HOME" bash -c 'source "$1"; cancel_pending_shutdown' _ "$ROOT/lidless.sh" 2>&1 || true
)"
mentions "with nothing pending it says so instead of staying silent" \
         "No automatic shutdown is pending" "$CANCEL_OUT"
if HOME="$CANCEL_HOME" bash -c 'source "$1"; cancel_pending_shutdown' _ "$ROOT/lidless.sh" >/dev/null 2>&1
then
  bad "cancel-shutdown reported success with nothing pending"
else
  ok "and still exits non-zero, so scripts can tell the difference"
fi

printf '%s\n' "$(( $(date +%s) + 60 ))" > "$CANCEL_HOME/.lidless_shutdown_pending"
CANCEL_OUT="$(
  HOME="$CANCEL_HOME" bash -c 'source "$1"; cancel_pending_shutdown' _ "$ROOT/lidless.sh" 2>&1
)"
mentions "with a shutdown pending it confirms the request" \
         "cancellation requested" "$CANCEL_OUT"
is "the pending marker is consumed" "absent" \
   "$( [ -f "$CANCEL_HOME/.lidless_shutdown_pending" ] && echo present || echo absent )"
is "and the cancel signal is left for whoever is sleeping on it" "present" \
   "$( [ -f "$CANCEL_HOME/.lidless_shutdown_cancel" ] && echo present || echo absent )"

# ---------------------------------------------------------------------------
section "set — validation refuses what the app's Pickers cannot display"
# ---------------------------------------------------------------------------
#
# The allowed sets are the Pickers' own tag sets (Sources/main.swift). The
# rejected values below are not arbitrary: 60 for screenLockDelay is the
# hand-written value docs/ARCHITECTURE.md records as leaving the Picker with nothing
# selected, and 3 / 15 sit plausibly between real choices — exactly what a
# person guessing the scale would type.

is "a boolean accepts 1"            "-bool true"  "$(validate_setting keepAwakeOnBattery 1)"
is "and the words people type: on"  "-bool true"  "$(validate_setting blackoutBuiltinDisplayV1 on)"
is "and no"                         "-bool false" "$(validate_setting relaxScreenLock no)"
fails "but not a stray number"      validate_setting lowPowerWhileActive 2
is "screenLockDelay accepts a Picker value" "-int 900" "$(validate_setting screenLockDelay 900)"
is "and 0, the Picker's Never"              "-int 0"   "$(validate_setting screenLockDelay 0)"
fails "but not 60 — the docs/ARCHITECTURE.md failure"  validate_setting screenLockDelay 60
is "shutdown hours accept 8"     "-int 8" "$(validate_setting automaticShutdownAfterHoursV1 8)"
fails "but not 3"                validate_setting automaticShutdownAfterHoursV1 3
is "battery percent accepts 30"  "-int 30" "$(validate_setting automaticShutdownBelowBatteryPercentV1 30)"
fails "but not 15"               validate_setting automaticShutdownBelowBatteryPercentV1 15
is "panel mode accepts dim"      "-string dim" "$(validate_setting panelModeV1 dim)"
fails "but not sideways"         validate_setting panelModeV1 sideways

VS_RC=0; validate_setting noSuchSetting 1 >/dev/null 2>&1 || VS_RC=$?
is "an unknown key is its own error code" "2" "$VS_RC"

is "every listed key has an allowed-values line" "9" \
   "$(for k in $LIDLESS_SETTING_KEYS; do setting_allowed_values "$k"; done | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
section "set — writing goes through the same gate"
# ---------------------------------------------------------------------------

SET_STORE="$TMP/set-defaults"
rm -f "$SET_STORE"
export FAKE_DEFAULTS="$SET_STORE"

SET_OUT="$(set_setting screenLockDelay 900 2>&1)" || bad "valid set exited non-zero"
mentions "a valid set is confirmed back"        "screenLockDelay = 900" "$SET_OUT"
mentions "and says the app needs no restart"    "picks this up immediately" "$SET_OUT"
is "and the value landed in the domain" "900" \
   "$(awk '$1 == "screenLockDelay" { print $2 }' "$SET_STORE")"

set_setting blackoutBuiltinDisplayV1 on >/dev/null 2>&1
is "a boolean round-trips as defaults read would print it" "1" \
   "$(awk '$1 == "blackoutBuiltinDisplayV1" { print $2 }' "$SET_STORE")"

if SET_OUT="$(set_setting screenLockDelay 60 2>&1)"; then
  bad "an invalid value exits non-zero (got 0)"
else
  ok "an invalid value exits non-zero"
fi
mentions "names the allowed set"                "Allowed: 0 (never), 300" "$SET_OUT"
mentions "and says why the set is closed"       "empty selection" "$SET_OUT"
is "and the domain still holds the last good value" "900" \
   "$(awk '$1 == "screenLockDelay" { print $2 }' "$SET_STORE")"

if SET_OUT="$(set_setting noSuchSetting 1 2>&1)"; then
  bad "an unknown key exits non-zero (got 0)"
else
  ok "an unknown key exits non-zero"
fi
mentions "and lists the real keys" "keepAwakeOnBattery" "$SET_OUT"

if SET_OUT="$(set_setting screenLockDelay 2>&1)"; then
  bad "a key with no value exits non-zero (got 0)"
else
  ok "a key with no value exits non-zero"
fi
mentions "and shows usage" "set <key> <value>" "$SET_OUT"

SET_OUT="$(set_setting 2>&1)" || bad "bare set exited non-zero"
mentions "bare set lists every key"          "panelModeV1" "$SET_OUT"
mentions "with the current value where set"  "screenLockDelay" "$SET_OUT"
mentions "and the fallback note where unset" "unset — the fallback" "$SET_OUT"

# Through the real dispatch, not the sourced function: proves the subcommand is
# wired and that usage() names it.
SET_OUT="$(bash "$ROOT/lidless.sh" set screenLockDelay 300 2>&1)" \
  || bad "dispatched set exited non-zero"
mentions "the set subcommand is dispatched" "screenLockDelay = 300" "$SET_OUT"
SET_OUT="$(bash "$ROOT/lidless.sh" bogus-command 2>&1 || true)"
mentions "and usage names it" "set    list the shared settings" "$SET_OUT"

unset FAKE_DEFAULTS

# ---------------------------------------------------------------------------
section "the panel log refuses a symlink planted at its target"
# ---------------------------------------------------------------------------
#
# Both candidate directories can be writable by another local process — beside
# the bundle because /Applications is drwxrwxr-x root:admin, and that is a
# corrected claim: the code used to argue the opposite in a comment. A symlink
# planted at the first candidate must not be followed, or the app appends its own
# writes into a file somebody else chose.
#
# Driven as a separate process (tests/swift/PanelLogHarness.swift), the same way
# LockHelper.swift is: Sources/PanelLog.swift is not in the parser test binary and
# its sink is private.

if command -v swiftc >/dev/null 2>&1; then
  PANELLOG_BIN_DIR="$TMP/panellog/bin"
  PANELLOG_HOME="$TMP/panellog/home"
  mkdir -p "$PANELLOG_BIN_DIR" "$PANELLOG_HOME"
  if swiftc -parse-as-library -o "$PANELLOG_BIN_DIR/panel-log-harness" \
       "$ROOT/Sources/PanelLog.swift" "$ROOT/tests/swift/PanelLogHarness.swift" \
       2>"$TMP/panellog-swiftc.log"; then

    # --- no symlink: the beside-the-binary candidate is used -----------------
    PANELLOG_BESIDE="$PANELLOG_BIN_DIR/lidless-panel.log"
    PANELLOG_OUT="$(HOME="$PANELLOG_HOME" "$PANELLOG_BIN_DIR/panel-log-harness")"
    is "the first candidate is the file beside the binary" \
       "$PANELLOG_BESIDE" "$PANELLOG_OUT"
    mentions "and the line really landed in it" "harness line" "$(cat "$PANELLOG_BESIDE")"

    # --- symlink planted at that exact path ----------------------------------
    PANELLOG_VICTIM="$TMP/panellog/victim"
    rm -f "$PANELLOG_BESIDE" "$PANELLOG_VICTIM"
    ln -s "$PANELLOG_VICTIM" "$PANELLOG_BESIDE"
    PANELLOG_OUT="$(HOME="$PANELLOG_HOME" "$PANELLOG_BIN_DIR/panel-log-harness")"
    if [ -e "$PANELLOG_VICTIM" ]; then
      bad "a symlink at the log path was followed"
    else
      ok "a symlink at the log path is not followed"
    fi
    is "and the writer falls back to ~/Library/Logs/Lidless" \
       "$PANELLOG_HOME/Library/Logs/Lidless/lidless-panel.log" "$PANELLOG_OUT"

    # --- a plain file owned by somebody else cannot be tested as another user,
    # but the same guard refuses a non-regular file, which can be ---------------
    rm -f "$PANELLOG_BESIDE"
    mkfifo "$PANELLOG_BESIDE"
    PANELLOG_OUT="$(HOME="$PANELLOG_HOME" "$PANELLOG_BIN_DIR/panel-log-harness")"
    is "a non-regular file at the log path is refused too" \
       "$PANELLOG_HOME/Library/Logs/Lidless/lidless-panel.log" "$PANELLOG_OUT"
    rm -f "$PANELLOG_BESIDE"
  else
    bad "swiftc could not build the panel log harness"
    sed 's/^/       /' "$TMP/panellog-swiftc.log"
  fi
else
  printf '  %sskip%s swiftc not installed — panel log path not checked\n' "$D" "$N"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n%s%s passed, %s failed%s\n' "$B" "$PASS" "$FAIL" "$N"
[ "$FAIL" -eq 0 ]
