// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Dmytro Udovychenko

import Foundation
import Darwin

// Tests for the app's parsers, run against the same fixture files as the shell
// parsers in tests/run.sh. The app and the script must agree about the same Mac,
// so every case here has a counterpart there.
//
// Compiled and run by tests/run.sh; takes the fixtures directory as argv[1].

@main
struct ParserTests {
    nonisolated(unsafe) static var passed = 0
    nonisolated(unsafe) static var failed = 0
    nonisolated(unsafe) static var fixtures = "."

    static func fixture(_ name: String) -> String {
        (try? String(contentsOfFile: "\(fixtures)/\(name)", encoding: .utf8)) ?? {
            print("  FAIL could not read fixture \(name)")
            failed += 1
            return ""
        }()
    }

    static func expect<T: Equatable>(_ name: String, _ expected: T, _ actual: T) {
        if expected == actual {
            passed += 1
            print("  ok   \(name)")
        } else {
            failed += 1
            print("  FAIL \(name)\n       expected: \(expected)\n       actual:   \(actual)")
        }
    }

    static func main() {
        if CommandLine.arguments.count > 1 { fixtures = CommandLine.arguments[1] }

        let macbook = fixture("pmset-custom-macbook.txt")
        let macmini = fixture("pmset-custom-macmini.txt")
        let acFirst = fixture("pmset-custom-ac-first.txt")

        print("\nSystemProbe.lowPower — laptop")
        expect("AC off", false, SystemProbe.lowPower(in: macbook, section: "AC Power"))
        expect("battery on", true, SystemProbe.lowPower(in: macbook, section: "Battery Power"))

        print("\nSystemProbe.lowPower — desktop (no Battery Power section)")
        expect("AC readable", false, SystemProbe.lowPower(in: macmini, section: "AC Power"))
        expect("absent battery section is false, not a crash",
               false, SystemProbe.lowPower(in: macmini, section: "Battery Power"))
        expect("hasBattery false", false, macmini.contains("Battery Power"))
        expect("hasBattery true", true, macbook.contains("Battery Power"))

        print("\nSystemProbe.lowPower — section order is not assumed")
        expect("AC when AC comes first", false, SystemProbe.lowPower(in: acFirst, section: "AC Power"))
        expect("battery when AC comes first", true, SystemProbe.lowPower(in: acFirst, section: "Battery Power"))

        // macOS 15 prints `powermode` for the same setting macOS 26 prints as
        // `lowpowermode`. Reading only the newer name made every Low Power Mode
        // reading on 15 unconfirmed — tile, save and restore all went with it.
        print("\nSystemProbe.lowPowerValue — macOS 15's `powermode` spelling")
        let sequoia = fixture("pmset-custom-sequoia.txt")
        expect("AC off", true, SystemProbe.lowPowerValue(in: sequoia, section: "AC Power") == false)
        expect("battery on", true, SystemProbe.lowPowerValue(in: sequoia, section: "Battery Power") == true)
        // High Power Mode: the restore only writes lowpowermode 0/1, so a
        // confirmed "off" here would demote the Mac on Disable.
        expect("powermode 2 is unconfirmed, not off", true,
               SystemProbe.lowPowerValue(in: "AC Power:\n powermode 2\n", section: "AC Power") == nil)
        // Both names in one section: the first row decides, malformed included
        // — mirroring shell's single awk pass over the two names.
        expect("malformed first row does not fall through to the other name", true,
               SystemProbe.lowPowerValue(
                   in: "AC Power:\n lowpowermode 1 garbage\n powermode 0\n",
                   section: "AC Power"
               ) == nil)

        // The sampler's give-up decision is one-way — it kills the sensor strip
        // for the life of the process — and it used to turn on elapsed time
        // alone. A main actor blocked by a synchronous privileged `pmset` (up
        // to Shell.defaultTimeout, twice the deadline) then delayed the
        // completion past it, and a healthy Mac was declared wedged.
        print("\nSensorSampling.sampleVerdict")
        expect("nothing in flight starts a sample", SensorSampleVerdict.start,
               SensorSampling.sampleVerdict(inFlight: false, elapsed: 999,
                                            callStarted: false, callReturned: false,
                                            abandonAfter: 10))
        expect("in flight and still young waits", SensorSampleVerdict.wait,
               SensorSampling.sampleVerdict(inFlight: true, elapsed: 3,
                                            callStarted: true, callReturned: false,
                                            abandonAfter: 10))
        expect("unanswered past the deadline is abandoned", SensorSampleVerdict.abandon,
               SensorSampling.sampleVerdict(inFlight: true, elapsed: 11,
                                            callStarted: true, callReturned: false,
                                            abandonAfter: 10))
        expect("answered but late back is a busy main actor, not a wedged kernel",
               SensorSampleVerdict.resetClock,
               SensorSampling.sampleVerdict(inFlight: true, elapsed: 30,
                                            callStarted: true, callReturned: true,
                                            abandonAfter: 10))
        // The sampling task is .background QoS and the main thread is blocked
        // for whole seconds at a time here; a task that never got a thread has
        // asked the SMC for nothing and cannot be wedged in it.
        expect("never given a thread is not a wedged kernel either",
               SensorSampleVerdict.resetClock,
               SensorSampling.sampleVerdict(inFlight: true, elapsed: 30,
                                            callStarted: false, callReturned: false,
                                            abandonAfter: 10))
        expect("the deadline is exclusive, not inclusive", SensorSampleVerdict.wait,
               SensorSampling.sampleVerdict(inFlight: true, elapsed: 10,
                                            callStarted: true, callReturned: false,
                                            abandonAfter: 10))

        print("\nSystemProbe.screenLock")
        expect("seconds", "900", SystemProbe.screenLock(in: fixture("sysadminctl-900.txt")))
        expect("off", "off", SystemProbe.screenLock(in: fixture("sysadminctl-off.txt")))
        expect("immediate", "immediate", SystemProbe.screenLock(in: fixture("sysadminctl-immediate.txt")))
        expect("a refusal is not a value", "unknown",
               SystemProbe.screenLock(in: fixture("sysadminctl-password-required.txt")))
        expect("empty", "unknown", SystemProbe.screenLock(in: ""))

        print("\nSystemProbe.sleepDisabled")
        expect("lid ignored", true, SystemProbe.sleepDisabled(in: fixture("pmset-g-sleepdisabled-on.txt")))
        // pmset-g-sleepdisabled-off.txt is a SYNTHETIC fixture (tests/fixtures/README.md)
        // — the "key absent means normal" behavior it encodes is not proven by
        // this fixture itself. It is confirmed by Apple's own open-source
        // pmset.c, show_system_power_settings(): the SleepDisabled line only
        // prints once the key exists in the settings dictionary, i.e. once it
        // has actually been set.
        expect("lid normal (key legitimately absent — real pmset omits it at 0)", false,
               SystemProbe.sleepDisabled(in: fixture("pmset-g-sleepdisabled-off.txt")))
        expect("key absent reads false", false, SystemProbe.sleepDisabled(in: macbook))
        // `pmset -g` separates its columns with tabs, not spaces. Splitting on a
        // literal " " read the whole line as one field and reported false on a
        // Mac that really was ignoring the lid.
        expect("tab-separated columns", true, SystemProbe.sleepDisabled(in: "System-wide power settings:\n SleepDisabled\t\t1\n"))
        expect("tab-separated, value 0", false, SystemProbe.sleepDisabled(in: " SleepDisabled\t\t0\n"))
        expect("present value is readable", true,
               SystemProbe.sleepDisabledValue(in: " SleepDisabled\t\t1\n") != nil)
        expect("key seen but no usable value (truncated) is nil, not false — a genuine parity",
               true, SystemProbe.sleepDisabledValue(in: " SleepDisabled\n") == nil)
        expect("an unrelated key that merely contains the substring is not matched — reads as absent (false)",
               false, SystemProbe.sleepDisabledValue(in: " NotSleepDisabled\t\t1\n"))
        // A missing key is the ordinary case (confirmed via pmset.c, see
        // above) and must read false, not nil — nil is
        // reserved for a value that is present but genuinely ambiguous, which
        // a missing key is not. Getting this backwards was the actual bug: an
        // earlier version of this fix treated "absent" as unknown, which would
        // have made every normal Mac's lid state read as unreadable.
        expect("key absent reads false, not nil", false,
               SystemProbe.sleepDisabledValue(in: macbook))
        expect("present but garbage value is nil, not false — unlike an absent key, this is genuinely ambiguous",
               true, SystemProbe.sleepDisabledValue(in: " SleepDisabled\t\t7\n") == nil)

        print("\nSystemProbe.batteryPercent")
        expect("on AC with a battery", 85, SystemProbe.batteryPercent(in: fixture("pmset-ps-ac.txt")))
        expect("on battery", 18, SystemProbe.batteryPercent(in: fixture("pmset-ps-battery.txt")))
        expect("desktop has none", nil, SystemProbe.batteryPercent(in: fixture("pmset-ps-desktop.txt")))

        print("\nSystemProbe.batteryTime")
        expect("discharging with an estimate", BatteryTime.remaining("1:04"),
               SystemProbe.batteryTime(in: fixture("pmset-ps-battery.txt")))
        expect("on AC, held below full: no time, and nothing wrong", BatteryTime.notCharging,
               SystemProbe.batteryTime(in: fixture("pmset-ps-ac.txt")))
        expect("desktop line has no battery at all", BatteryTime.unknown,
               SystemProbe.batteryTime(in: fixture("pmset-ps-desktop.txt")))
        expect("charging counts up to full", BatteryTime.toFull("1:23"),
               SystemProbe.batteryTime(in:
                   " -InternalBattery-0 (id=22806627)\t85%; charging; 1:23 remaining present: true\n"))
        // `discharging` and `not charging` both contain `charging`, and a charged
        // battery still prints a `0:00 remaining` an eager parser would show as a
        // countdown. Each of these three would pass if the checks were reordered.
        expect("charged is not 0:00 to full", BatteryTime.charged,
               SystemProbe.batteryTime(in:
                   " -InternalBattery-0 (id=22806627)\t100%; charged; 0:00 remaining present: true\n"))
        expect("discharging is not charging", BatteryTime.remaining("2:30"),
               SystemProbe.batteryTime(in:
                   " -InternalBattery-0 (id=22806627)\t70%; discharging; 2:30 remaining present: true\n"))
        expect("finishing charge still counts to full", BatteryTime.toFull("0:04"),
               SystemProbe.batteryTime(in:
                   " -InternalBattery-0 (id=22806627)\t99%; finishing charge; 0:04 remaining present: true\n"))
        expect("no estimate yet is not unknown — macOS is still working it out",
               BatteryTime.estimating,
               SystemProbe.batteryTime(in:
                   " -InternalBattery-0 (id=22806627)\t64%; discharging; (no estimate) present: true\n"))
        expect("garbage without a percentage is unknown", BatteryTime.unknown,
               SystemProbe.batteryTime(in: "Now drawing from 'Battery Power'\n"))

        // One wording for both the window and the menu bar panel — they render the
        // same estimate from this one property, so a change here moves both.
        print("\nBatteryTime.summary")
        expect("discharging", "1:04 left", BatteryTime.remaining("1:04").summary)
        expect("charging", "1:23 to full", BatteryTime.toFull("1:23").summary)
        expect("charged", "charged", BatteryTime.charged.summary)
        expect("held below full", "not charging", BatteryTime.notCharging.summary)
        expect("no estimate yet", "estimating…", BatteryTime.estimating.summary)
        expect("unreadable", "unknown", BatteryTime.unknown.summary)

        print("\nSystemProbe.clamshellClosed")
        let clamshell = fixture("ioreg-clamshell-macbook.txt")
        expect("lid open", false, SystemProbe.clamshellClosed(in: clamshell))
        expect("lid closed", true,
               SystemProbe.clamshellClosed(in: clamshell.replacingOccurrences(
                   of: "\"AppleClamshellState\" = No", with: "\"AppleClamshellState\" = Yes")))
        // The surrounding ioreg output is full of unrelated `= Yes` values, so a
        // whole-text search for "Yes" would report every MacBook as lid-closed.
        expect("desktop has no lid state", false, SystemProbe.clamshellClosed(in: fixture("ioreg-desktop.txt")))

        print("\nRestore-state validation")
        let lowPower = SystemProbe.savedLowPower(in: "0:1\n")
        expect("valid low-power AC", 0, lowPower?.ac)
        expect("valid low-power battery", 1, lowPower?.battery)
        expect("reject low-power value outside 0/1", nil,
               SystemProbe.savedLowPower(in: "0:2")?.ac)
        expect("reject extra low-power fields", nil,
               SystemProbe.savedLowPower(in: "0:1:0")?.ac)
        expect("reject low-power shell syntax", nil,
               SystemProbe.savedLowPower(in: "0:1; /usr/bin/false")?.ac)

        expect("saved screen-lock seconds", "900", SystemProbe.savedScreenLock(in: "0900\n"))
        expect("saved screen-lock off", "off", SystemProbe.savedScreenLock(in: "off"))
        expect("saved screen-lock immediate", "immediate", SystemProbe.savedScreenLock(in: "immediate"))
        expect("reject negative screen-lock", nil, SystemProbe.savedScreenLock(in: "-1"))
        expect("reject screen-lock shell syntax", nil,
               SystemProbe.savedScreenLock(in: "900; /usr/bin/false"))

        let enabledAt = SystemProbe.enabledAt(in: "1700000000\n")
        expect("enabled-at timestamp", 1_700_000_000,
               enabledAt.map { Int($0.timeIntervalSince1970) })
        expect("reject zero enabled-at", nil, SystemProbe.enabledAt(in: "0"))
        expect("reject malformed enabled-at", nil, SystemProbe.enabledAt(in: "yesterday"))

        print("\nStructured commands")
        let literalArgument = "0; /usr/bin/false"
        let commandResult = Shell.run(Shell.Command("/bin/echo", [literalArgument]))
        expect("structured command succeeds", Int32(0), commandResult.status)
        expect("shell syntax remains one literal argv", literalArgument, commandResult.output)

        print("\nInterprocess lock (acquireLock/releaseLock — flock(2) on the open file description,")
        print("not the process, so two opens of the same path in this one process already exercise it)")
        let lockPath = NSTemporaryDirectory() + "lidless-swift-locktest-\(ProcessInfo.processInfo.processIdentifier)"
        try? FileManager.default.removeItem(atPath: lockPath)
        if let fd1 = SystemProbe.acquireLock(path: lockPath) {
            passed += 1
            print("  ok   first acquire succeeds")
            let fd2 = SystemProbe.acquireLock(path: lockPath)
            expect("second acquire on the same path fails while the first is held", true, fd2 == nil)
            SystemProbe.releaseLock(fd1)
            let fd3 = SystemProbe.acquireLock(path: lockPath)
            expect("acquires again once released", true, fd3 != nil)
            if let fd3 { SystemProbe.releaseLock(fd3) }
        } else {
            failed += 1
            print("  FAIL first acquire failed unexpectedly")
        }
        try? FileManager.default.removeItem(atPath: lockPath)

        print("\nSystemProbe.privilegedSupportInstalled")
        let fakeSudoPath: String = URL(fileURLWithPath: fixtures)
            .deletingLastPathComponent()
            .appendingPathComponent("bin/sudo")
            .path
        _ = setenv("FAKE_SUDO_DENY", "0", 1)
        expect(
            "an outdated executable helper is not reported as installed",
            false,
            SystemProbe.privilegedSupportInstalled(
                helperPath: "/usr/bin/true",
                sudoPath: fakeSudoPath
            )
        )
        expect(
            "a helper with the complete allowed command set passes the permission check",
            true,
            SystemProbe.privilegedSupportInstalled(
                helperPath: "/usr/bin/true",
                sudoPath: fakeSudoPath,
                requiredVersionMarker: nil
            )
        )
        _ = setenv("FAKE_SUDO_DENY_MATCH", "disablesleep 0", 1)
        expect(
            "a setup missing the Disable command is reported as incomplete",
            false,
            SystemProbe.privilegedSupportInstalled(
                helperPath: "/usr/bin/true",
                sudoPath: fakeSudoPath,
                requiredVersionMarker: nil
            )
        )
        _ = setenv("FAKE_SUDO_DENY_MATCH", "lowpowermode 1", 1)
        expect(
            "a setup missing a Low Power Mode command is reported as incomplete",
            false,
            SystemProbe.privilegedSupportInstalled(
                helperPath: "/usr/bin/true",
                sudoPath: fakeSudoPath,
                requiredVersionMarker: nil
            )
        )
        _ = unsetenv("FAKE_SUDO_DENY_MATCH")
        _ = setenv("FAKE_SUDO_DENY", "1", 1)
        expect(
            "an existing helper is not installed when sudo denies this user",
            false,
            SystemProbe.privilegedSupportInstalled(
                helperPath: "/usr/bin/true",
                sudoPath: fakeSudoPath,
                requiredVersionMarker: nil
            )
        )
        _ = unsetenv("FAKE_SUDO_DENY")
        expect(
            "a missing helper is never reported as installed",
            false,
            SystemProbe.privilegedSupportInstalled(
                helperPath: "/does/not/exist/lidless-helper",
                sudoPath: fakeSudoPath,
                requiredVersionMarker: nil
            )
        )

        print("\nSystemState.lidPresentation")
        var lidState = SystemState()
        lidState.lidStateReadable = false
        expect("unreadable is unknown regardless of lidIgnored's default", LidPresentation.unknown,
               lidState.lidPresentation)
        lidState.lidStateReadable = true
        lidState.lidIgnored = true
        expect("readable and ignored", LidPresentation.ignored, lidState.lidPresentation)
        lidState.lidIgnored = false
        expect("readable and normal", LidPresentation.normal, lidState.lidPresentation)

        print("\nSystemProbe.shouldEvaluateAutoOffLimits")
        expect("ignored evaluates limits without state files", true,
               SystemProbe.shouldEvaluateAutoOffLimits(
                   lidPresentation: .ignored, hasSessionEvidence: false))
        expect("ignored also evaluates limits with state files", true,
               SystemProbe.shouldEvaluateAutoOffLimits(
                   lidPresentation: .ignored, hasSessionEvidence: true))
        expect("normal does not evaluate limits without state files", false,
               SystemProbe.shouldEvaluateAutoOffLimits(
                   lidPresentation: .normal, hasSessionEvidence: false))
        expect("normal remains inactive even with stale state evidence", false,
               SystemProbe.shouldEvaluateAutoOffLimits(
                   lidPresentation: .normal, hasSessionEvidence: true))
        expect("unknown alone does not force an automatic change", false,
               SystemProbe.shouldEvaluateAutoOffLimits(
                   lidPresentation: .unknown, hasSessionEvidence: false))
        expect("unknown with tracked session evidence evaluates configured limits", true,
               SystemProbe.shouldEvaluateAutoOffLimits(
                   lidPresentation: .unknown, hasSessionEvidence: true))

        print("\nSystemProbe.strandedHeartbeatDecision")
        expect("no heartbeat file at all is nothing to adopt", SystemProbe.StrandedHeartbeatVerdict.leftover,
               SystemProbe.strandedHeartbeatDecision(age: nil))
        expect("a heartbeat older than the staleness window is a leftover",
               SystemProbe.StrandedHeartbeatVerdict.leftover,
               SystemProbe.strandedHeartbeatDecision(age: 60))
        expect("exactly at the threshold counts as a leftover, matching the rescue tool",
               SystemProbe.StrandedHeartbeatVerdict.leftover,
               SystemProbe.strandedHeartbeatDecision(age: SystemProbe.panelHeartbeatStaleAfter))
        // The bug: a second instance deleting the first one's live heartbeat.
        expect("a heartbeat touched a moment ago belongs to somebody",
               SystemProbe.StrandedHeartbeatVerdict.liveOwner,
               SystemProbe.strandedHeartbeatDecision(age: 2))
        expect("and one just under the threshold still does",
               SystemProbe.StrandedHeartbeatVerdict.liveOwner,
               SystemProbe.strandedHeartbeatDecision(age: SystemProbe.panelHeartbeatStaleAfter - 0.1))
        // Opposite direction to DisplayRescue's handling of the same reading, on
        // purpose: there, not firing costs the screen; here, deleting costs
        // somebody else's screen.
        expect("a clock that moved backwards is treated as live, not as stale",
               SystemProbe.StrandedHeartbeatVerdict.liveOwner,
               SystemProbe.strandedHeartbeatDecision(age: -5))

        print("\nSystemProbe.screenLockRestorePointIsSpent")
        expect("an applied restore deletes the point it consumed", true,
               SystemProbe.screenLockRestorePointIsSpent(
                   commandApplied: true, savingCurrent: false, lockHeld: true))
        // The contention branch. Deleting here is what left a Mac permanently
        // unlocked with nothing on disk to undo it.
        expect("a lock we could not take keeps the restore point", false,
               SystemProbe.screenLockRestorePointIsSpent(
                   commandApplied: true, savingCurrent: false, lockHeld: false))
        expect("a call that just SAVED the value never consumes it", false,
               SystemProbe.screenLockRestorePointIsSpent(
                   commandApplied: true, savingCurrent: true, lockHeld: true))
        expect("a command that did not apply keeps the restore point", false,
               SystemProbe.screenLockRestorePointIsSpent(
                   commandApplied: false, savingCurrent: false, lockHeld: true))
        expect("and no combination of failures deletes it", false,
               SystemProbe.screenLockRestorePointIsSpent(
                   commandApplied: false, savingCurrent: true, lockHeld: false))

        print("\nSystemProbe.automaticShutdownStillWarranted")
        // The grace period used to carry only its display string, so nothing
        // could be re-checked when it expired. Each case below is a thing a user
        // can plausibly do in those 60 seconds.
        func stillWarranted(
            _ trigger: SystemProbe.AutomaticShutdownTrigger,
            evidence: Bool = true,
            elapsed: TimeInterval? = 6 * 3600,
            hours: Int = 4,
            readable: Bool = true,
            onBattery: Bool = true,
            percent: Int? = 18,
            threshold: Int = 20
        ) -> Bool {
            SystemProbe.automaticShutdownStillWarranted(
                trigger: trigger, hasSessionEvidence: evidence, sessionElapsed: elapsed,
                hoursLimit: hours, powerSourceReadable: readable, onBattery: onBattery,
                batteryPercent: percent, batteryThreshold: threshold
            )
        }
        expect("an hours limit still exceeded still fires", true, stillWarranted(.hours(4)))
        expect("a session restarted during the grace abandons it", false,
               stillWarranted(.hours(4), elapsed: 60))
        expect("a session ended during the grace abandons it", false,
               stillWarranted(.hours(4), evidence: false))
        expect("no timestamp to measure against abandons it", false,
               stillWarranted(.hours(4), elapsed: nil))
        expect("clearing the hours limit during the grace abandons it", false,
               stillWarranted(.hours(4), hours: 0))
        expect("a battery still under the threshold still fires", true,
               stillWarranted(.batteryPercent(18)))
        expect("the charger going in abandons it — the whole point of the grace", false,
               stillWarranted(.batteryPercent(18), onBattery: false))
        expect("charge risen back above the threshold abandons it", false,
               stillWarranted(.batteryPercent(18), percent: 40))
        expect("an unreadable power source abandons it rather than guessing", false,
               stillWarranted(.batteryPercent(18), readable: false))
        expect("clearing the battery limit during the grace abandons it", false,
               stillWarranted(.batteryPercent(18), threshold: 0))
        // The two arms are independent: an hours shutdown must not be talked out
        // of firing by a healthy battery, or vice versa.
        expect("an hours trigger ignores the battery reading", true,
               stillWarranted(.hours(4), onBattery: false, percent: 100, threshold: 0))
        expect("a battery trigger ignores the session clock", true,
               stillWarranted(.batteryPercent(18), elapsed: 60, hours: 0))
        expect("the reason string is the wording both sides show", "after 4h",
               SystemProbe.AutomaticShutdownTrigger.hours(4).reason)
        expect("and for the battery arm it names the measured percentage", "battery at 18%",
               SystemProbe.AutomaticShutdownTrigger.batteryPercent(18).reason)

        print("\nSystemProbe.isCaffeinateProcessResult")
        // Extracted from `isCaffeinateProcess`, which kept `Shell.run` and this
        // rule fused and therefore untestable — while its immediate neighbour
        // `caffeinatePIDQuery` had been split for exactly this reason. The rule
        // decides whether a recorded PID is still the caffeinate the app
        // started, and it must agree with the shell's `is_caffeinate_pid`.
        expect("a bare name matches", true,
               SystemProbe.isCaffeinateProcessResult(status: 0, output: "caffeinate"))
        expect("a full path matches on its basename", true,
               SystemProbe.isCaffeinateProcessResult(status: 0, output: "/usr/bin/caffeinate"))
        expect("trailing whitespace does not stop a match", true,
               SystemProbe.isCaffeinateProcessResult(status: 0, output: "/usr/bin/caffeinate\n"))
        // The reason this is an exact basename comparison and not a substring:
        // a reused pid whose new owner is named like this must not pass.
        expect("a name merely containing caffeinate does not match", false,
               SystemProbe.isCaffeinateProcessResult(status: 0, output: "my-caffeinate-wrapper"))
        expect("nor does a path whose directory is the match", false,
               SystemProbe.isCaffeinateProcessResult(status: 0, output: "/opt/caffeinate/runner"))
        expect("a dead pid (ps exits non-zero) is not caffeinate", false,
               SystemProbe.isCaffeinateProcessResult(status: 1, output: ""))
        expect("empty output with a zero status is not a match either", false,
               SystemProbe.isCaffeinateProcessResult(status: 0, output: ""))
        expect("and neither is whitespace on its own", false,
               SystemProbe.isCaffeinateProcessResult(status: 0, output: "  \n"))

        print("\nSystemProbe.caffeinatePIDQueryResult")
        expect("pgrep matches become a complete PID set", CaffeinatePIDQueryResult.found([101, 202]),
               SystemProbe.caffeinatePIDQueryResult(status: 0, output: "101\n202\n"))
        expect("pgrep status 1 means no matches", CaffeinatePIDQueryResult.none,
               SystemProbe.caffeinatePIDQueryResult(status: 1, output: ""))
        expect("pgrep status 2 is an enumeration failure, not no matches", CaffeinatePIDQueryResult.failed,
               SystemProbe.caffeinatePIDQueryResult(status: 2, output: ""))
        expect("a launch failure is an enumeration failure", CaffeinatePIDQueryResult.failed,
               SystemProbe.caffeinatePIDQueryResult(status: -1, output: "launch failed"))
        expect("status 0 with empty output is inconsistent and fails closed", CaffeinatePIDQueryResult.failed,
               SystemProbe.caffeinatePIDQueryResult(status: 0, output: ""))
        expect("malformed successful output is rejected as an incomplete target set",
               CaffeinatePIDQueryResult.failed,
               SystemProbe.caffeinatePIDQueryResult(status: 0, output: "101\nnot-a-pid\n"))

        print("\nSystemProbe.lidIgnoredResult (lidIgnored()'s routing, without shelling out)")
        expect("status != 0 is nil", true, SystemProbe.lidIgnoredResult(status: 1, output: "") == nil)
        expect("status 0 but empty output is nil, not false", true,
               SystemProbe.lidIgnoredResult(status: 0, output: "") == nil)
        expect("status 0, key absent, routes to sleepDisabledValue's false (not the folding wrapper)",
               false, SystemProbe.lidIgnoredResult(status: 0, output: macbook))
        expect("status 0, garbage value, routes through as nil — proves this does NOT use the",
               true, SystemProbe.lidIgnoredResult(status: 0, output: " SleepDisabled\t\t9\n") == nil)
        // folding sleepDisabled(in:) wrapper, which would have turned that nil into false.
        expect("status 0, ignored", true,
               SystemProbe.lidIgnoredResult(status: 0, output: fixture("pmset-g-sleepdisabled-on.txt")) == true)

        print("\nSystemProbe.powerSourceResult (malformed response is unreadable, not AC)")
        let acFixture = fixture("pmset-ps-ac.txt")
        let batteryFixture = fixture("pmset-ps-battery.txt")
        var result = SystemProbe.powerSourceResult(status: 0, output: acFixture)
        expect("AC: readable", true, result.readable)
        expect("AC: not on battery", false, result.onBattery)
        result = SystemProbe.powerSourceResult(status: 0, output: batteryFixture)
        expect("battery: readable", true, result.readable)
        expect("battery: on battery", true, result.onBattery)
        result = SystemProbe.powerSourceResult(status: 1, output: "")
        expect("failed probe: unreadable", false, result.readable)
        expect("failed probe: not treated as AC", false, result.onBattery)
        result = SystemProbe.powerSourceResult(status: 0, output: "garbage, no recognized header\n")
        expect("malformed-but-nonempty, status 0: unreadable, not silently AC", false, result.readable)
        expect("malformed-but-nonempty: not treated as AC either", false, result.onBattery)
        result = SystemProbe.powerSourceResult(
            status: 0, output: "error involving AC Power and Battery Power\n"
        )
        expect("a message that merely mentions both phrases (not the exact anchor) is unreadable",
               false, result.readable)
        result = SystemProbe.powerSourceResult(
            status: 0, output: "Warning: could not confirm 'Now drawing from 'AC Power'' this cycle\n"
        )
        expect("a diagnostic quoting the exact phrase (not as its own whole line) is still unreadable",
               false, result.readable)
        result = SystemProbe.powerSourceResult(
            status: 0,
            output: "Now drawing from 'AC Power'\nNow drawing from 'Battery Power'\n"
        )
        expect("both canonical lines present (contradictory) is unreadable, not silently the first match",
               false, result.readable)

        print("\nSystemProbe.sleepDisabledValue: exactly two fields, matching shell's $2 (not .last)")
        expect("a stray extra token must not fall through to whatever the last field happens to be",
               true, SystemProbe.sleepDisabledValue(in: " SleepDisabled garbage 1\n") == nil)

        print("\nSystemProbe.lowPowerValue: garbage value is nil, not false")
        expect("a value that is neither 0 nor 1 is unconfirmed, not confirmed-off",
               true, SystemProbe.lowPowerValue(in: " AC Power:\n lowpowermode 7\n", section: "AC Power") == nil)
        // Exactly two fields, matching shell's awk `$1 == key { val = $2 }` —
        // a stray extra token used to fall through to `.last` here while
        // shell's `$2` disagreed, the same parity bug already fixed for
        // sleepDisabledValue above. review round 6.
        expect("extra trailing token is unreadable, not the value in field 2",
               true, SystemProbe.lowPowerValue(in: "AC Power:\n lowpowermode 1 garbage\n", section: "AC Power") == nil)
        expect("extra leading-side token (still 3 fields) is unreadable too",
               true, SystemProbe.lowPowerValue(in: "AC Power:\n lowpowermode garbage 1\n", section: "AC Power") == nil)

        print("\nSystemProbe.batteryPresenceResult (cross-checked tri-state)")
        let macbookBattery = fixture("pmset-ps-battery.txt")
        expect("both probes confirm a battery", BatteryPresence.yes,
               SystemProbe.batteryPresenceResult(
                   customStatus: 0, custom: macbook,
                   batteryStatus: 0, batteryInfo: macbookBattery))
        expect("both probes confirm a desktop", BatteryPresence.no,
               SystemProbe.batteryPresenceResult(
                   customStatus: 0, custom: macmini,
                   batteryStatus: 0, batteryInfo: fixture("pmset-ps-desktop.txt")))
        expect("custom says no battery, but batt disagrees — the cross-check wins, not a confirmed no",
               BatteryPresence.yes,
               SystemProbe.batteryPresenceResult(
                   customStatus: 0, custom: macmini,
                   batteryStatus: 0, batteryInfo: macbookBattery))
        expect("both probes failed outright", BatteryPresence.unknown,
               SystemProbe.batteryPresenceResult(
                   customStatus: 1, custom: "",
                   batteryStatus: 1, batteryInfo: ""))

        // The gap this closes was not a laxer check in the menu bar — it was no
        // check at all, on a button calling the same `Lidless.enable()` the
        // window's guarded button calls. Both surfaces and the controller now
        // read this one function.
        // One snapshot runs up to fourteen sequential Shell calls, each capped at
        // 20s and nothing capping the sum — a worst case of minutes, which is
        // indistinguishable from the wedged refresh the per-probe timeout exists
        // to prevent. The budget is a parameter purely so the exhausted path is
        // reachable here in milliseconds rather than 75 seconds.
        print("\nSystemProbe.read: the overall budget")
        let budgetStarted = ContinuousClock.now
        let starved = SystemProbe.read(
            pidFile: "/nonexistent-lidless-pid-file",
            privilegedSupportOverride: false,
            budget: .zero
        )
        expect("an exhausted budget returns without running a single probe",
               true, budgetStarted.duration(to: .now) < .seconds(2))
        // Not a new failure mode: each of these is the same value the field
        // already carries when its own probe fails, which is the whole reason a
        // partial snapshot is safe to hand back.
        expect("...leaving the lid setting unreadable rather than claiming one",
               false, starved.lidStateReadable)
        expect("...and the power settings unreadable", false, starved.powerSettingsReadable)
        expect("...and the power source unreadable", false, starved.powerSourceReadable)
        expect("...and the screen-lock delay at its unknown default",
               "unknown", starved.screenLockDelay)
        expect("...and no caffeinate claimed", true, starved.caffeinatePID == nil)
        // The budget must not silently swallow an explicitly supplied value.
        expect("...while an overridden privileged answer is still honoured",
               false, starved.privilegedSupportInstalled)
        expect("the default budget is a real ceiling, not zero or absent",
               true, SystemProbe.readOverallBudget > .seconds(20))
        // The one field that must NOT read like a failed probe. Everything above
        // is deliberately identical to a probe that ran and found nothing;
        // without this flag a starved read is indistinguishable from a Mac with
        // no clamshell key, and on 2026-08-03 that ambiguity was the difference
        // between "the sensor glitched" and "my own budget change restored the
        // panel under a closed lid".
        expect("...but the snapshot admits the probes were skipped",
               true, starved.probesSkippedForBudget)
        // D3a: a read that answers instantly because it gave up must not be
        // mistaken for a read that answered instantly because the machine was
        // healthy. The duration is stamped either way.
        expect("...and reports how long it took, even when that is nearly nothing",
               true, starved.readDuration >= .zero && starved.readDuration < .seconds(2))
        let unstarved = SystemProbe.read(
            pidFile: "/nonexistent-lidless-pid-file",
            privilegedSupportOverride: false
        )
        expect("...and a read with budget to spare does not claim they were",
               false, unstarved.probesSkippedForBudget)

        print("\nSystemProbe.privilegeSetupBlocksEnable")
        expect("no limit selected: nothing to block, permission or not", false,
               SystemProbe.privilegeSetupBlocksEnable(
                   shutdownAfterHours: 0, shutdownBelowBatteryPercent: 0,
                   privilegedSupportInstalled: false))
        expect("an hours limit without the permission blocks", true,
               SystemProbe.privilegeSetupBlocksEnable(
                   shutdownAfterHours: 3, shutdownBelowBatteryPercent: 0,
                   privilegedSupportInstalled: false))
        // Either limit alone is enough — the battery one is the easier to forget,
        // and it arms exactly the same power-off.
        expect("a battery limit without the permission blocks", true,
               SystemProbe.privilegeSetupBlocksEnable(
                   shutdownAfterHours: 0, shutdownBelowBatteryPercent: 15,
                   privilegedSupportInstalled: false))
        expect("both limits without the permission blocks", true,
               SystemProbe.privilegeSetupBlocksEnable(
                   shutdownAfterHours: 3, shutdownBelowBatteryPercent: 15,
                   privilegedSupportInstalled: false))
        expect("a limit WITH the permission installed does not block", false,
               SystemProbe.privilegeSetupBlocksEnable(
                   shutdownAfterHours: 3, shutdownBelowBatteryPercent: 15,
                   privilegedSupportInstalled: true))
        // A missing permission is only a blocker when something needs it; the
        // app is still perfectly usable without automatic shutdown.
        expect("no permission and no limit is an ordinary, allowed session", false,
               SystemProbe.privilegeSetupBlocksEnable(
                   shutdownAfterHours: 0, shutdownBelowBatteryPercent: 0,
                   privilegedSupportInstalled: true))

        print("\nSystemProbe.lowPowerEnableDecision (Phase 5's promised pure Enable seam)")
        expect("not requested: skip, no message", LowPowerEnableDecision.skip(message: nil),
               SystemProbe.lowPowerEnableDecision(
                   wantsLowPower: false, lowPowerActiveEverywhere: false,
                   powerSettingsReadable: true, currentValuesReadable: true,
                   hasSavedLowPowerFile: false, savedLowPowerValid: true))
        expect("already active everywhere: skip, no message", LowPowerEnableDecision.skip(message: nil),
               SystemProbe.lowPowerEnableDecision(
                   wantsLowPower: true, lowPowerActiveEverywhere: true,
                   powerSettingsReadable: true, currentValuesReadable: true,
                   hasSavedLowPowerFile: false, savedLowPowerValid: true))
        expect("unreadable power settings: skip with message, NOT the whole-Enable-aborting bug this replaced",
               LowPowerEnableDecision.skip(message: "Could not read the current Low Power Mode; it was left unchanged."),
               SystemProbe.lowPowerEnableDecision(
                   wantsLowPower: true, lowPowerActiveEverywhere: false,
                   powerSettingsReadable: false, currentValuesReadable: true,
                   hasSavedLowPowerFile: false, savedLowPowerValid: true))
        expect("current values unreadable, no saved file yet: skip with message, not a fabricated 0:0 save",
               LowPowerEnableDecision.skip(message: "Could not read the current Low Power Mode values; it was left unchanged."),
               SystemProbe.lowPowerEnableDecision(
                   wantsLowPower: true, lowPowerActiveEverywhere: false,
                   powerSettingsReadable: true, currentValuesReadable: false,
                   hasSavedLowPowerFile: false, savedLowPowerValid: true))
        expect("current values unreadable but a saved file already exists: attempt (nothing new to read)",
               LowPowerEnableDecision.attempt,
               SystemProbe.lowPowerEnableDecision(
                   wantsLowPower: true, lowPowerActiveEverywhere: false,
                   powerSettingsReadable: true, currentValuesReadable: false,
                   hasSavedLowPowerFile: true, savedLowPowerValid: true))
        expect("saved state invalid: skip with message", LowPowerEnableDecision.skip(message: "Saved Low Power Mode state is invalid; it was left unchanged."),
               SystemProbe.lowPowerEnableDecision(
                   wantsLowPower: true, lowPowerActiveEverywhere: false,
                   powerSettingsReadable: true, currentValuesReadable: true,
                   hasSavedLowPowerFile: true, savedLowPowerValid: false))
        expect("no saved file yet: attempt (nothing to validate)", LowPowerEnableDecision.attempt,
               SystemProbe.lowPowerEnableDecision(
                   wantsLowPower: true, lowPowerActiveEverywhere: false,
                   powerSettingsReadable: true, currentValuesReadable: true,
                   hasSavedLowPowerFile: false, savedLowPowerValid: true))
        expect("everything fine: attempt", LowPowerEnableDecision.attempt,
               SystemProbe.lowPowerEnableDecision(
                   wantsLowPower: true, lowPowerActiveEverywhere: false,
                   powerSettingsReadable: true, currentValuesReadable: true,
                   hasSavedLowPowerFile: true, savedLowPowerValid: true))

        print("\nSystemProbe.lowPowerValue (nil when unconfirmed, unlike lowPower(in:section:)'s false default)")
        expect("confirmed 1", true, SystemProbe.lowPowerValue(in: macbook, section: "Battery Power") == true)
        expect("confirmed 0", false, SystemProbe.lowPowerValue(in: macbook, section: "AC Power") == true)
        expect("section absent is nil, not false", true,
               SystemProbe.lowPowerValue(in: macmini, section: "Battery Power") == nil)
        expect("key absent from an otherwise-present section is nil", true,
               SystemProbe.lowPowerValue(in: "AC Power:\n standby 1\n", section: "AC Power") == nil)

        print("\nLow Power Mode across sources")
        var state = SystemState()
        state.hasBattery = true
        state.lowPowerAC = true
        state.lowPowerBattery = false
        expect("one laptop source is not enough", false, state.lowPowerActiveEverywhere)
        state.lowPowerBattery = true
        expect("both laptop sources are active", true, state.lowPowerActiveEverywhere)
        state.hasBattery = false
        state.lowPowerBattery = false
        expect("desktop only needs AC", true, state.lowPowerActiveEverywhere)

        print("\nSystemProbe.savedDisplayBrightness (~/.lidless_display_prev holds one value)")
        expect("a normal value", Float(0.0625), SystemProbe.savedDisplayBrightness(in: "0.0625\n"))
        expect("zero is a legal stored value", Float(0), SystemProbe.savedDisplayBrightness(in: "0"))
        expect("full brightness", Float(1), SystemProbe.savedDisplayBrightness(in: " 1.0 "))
        expect("above one is rejected", true, SystemProbe.savedDisplayBrightness(in: "1.5") == nil)
        expect("negative is rejected", true, SystemProbe.savedDisplayBrightness(in: "-0.5") == nil)
        expect("non-numeric is rejected", true, SystemProbe.savedDisplayBrightness(in: "abc") == nil)
        expect("empty is rejected", true, SystemProbe.savedDisplayBrightness(in: "") == nil)
        expect("shell injection is rejected", true,
               SystemProbe.savedDisplayBrightness(in: "0.5; /usr/bin/false") == nil)
        expect("infinity is rejected", true, SystemProbe.savedDisplayBrightness(in: "inf") == nil)

        print("\nSystemProbe.blackoutDecision (never blind the Mac)")
        expect("proceeds when a virtual display is confirmed active",
               BlackoutDecision.proceed(builtinID: 1),
               SystemProbe.blackoutDecision(activeDisplayIDs: [1, 4], builtinID: 1, virtualDisplayID: 4))
        expect("refuses BECAUSE the list is unreadable, not for some later reason",
               BlackoutDecision.refuse(reason: "the list of active displays could not be read"),
               SystemProbe.blackoutDecision(activeDisplayIDs: nil, builtinID: 1, virtualDisplayID: 4))
        expect("refuses with no built-in",
               BlackoutDecision.refuse(reason: "no built-in display was found"),
               SystemProbe.blackoutDecision(activeDisplayIDs: [4], builtinID: nil, virtualDisplayID: 4))
        expect("refuses with no virtual display",
               BlackoutDecision.refuse(reason: "no virtual display was created"),
               SystemProbe.blackoutDecision(activeDisplayIDs: [1], builtinID: 1, virtualDisplayID: nil))
        expect("refuses when the virtual display claims the built-in's ID",
               BlackoutDecision.refuse(reason: "the virtual display reported the built-in's own ID"),
               SystemProbe.blackoutDecision(activeDisplayIDs: [1], builtinID: 1, virtualDisplayID: 1))
        expect("refuses when the built-in is not active anyway",
               BlackoutDecision.refuse(reason: "the built-in display is not active to begin with"),
               SystemProbe.blackoutDecision(activeDisplayIDs: [4], builtinID: 1, virtualDisplayID: 4))
        expect("refuses when the virtual display is not in the active list",
               BlackoutDecision.refuse(reason: "the virtual display is not in the active list"),
               SystemProbe.blackoutDecision(activeDisplayIDs: [1], builtinID: 1, virtualDisplayID: 4))
        expect("refuses when the built-in is the only active display",
               BlackoutDecision.refuse(reason: "the virtual display reported the built-in's own ID"),
               SystemProbe.blackoutDecision(activeDisplayIDs: [1], builtinID: 1, virtualDisplayID: 1))
        expect("an empty active list is a refusal, not a licence",
               BlackoutDecision.refuse(reason: "the built-in display is not active to begin with"),
               SystemProbe.blackoutDecision(activeDisplayIDs: [], builtinID: 1, virtualDisplayID: 4))
        expect("proceeds with a real external display present too",
               BlackoutDecision.proceed(builtinID: 1),
               SystemProbe.blackoutDecision(activeDisplayIDs: [1, 3, 4], builtinID: 1, virtualDisplayID: 4))

        print("\nSystemProbe.virtualDisplayModeDimensions")
        expect("Apple Silicon keeps physical pixels for WindowServer to halve",
               VirtualDisplayModeDimensions(width: 2940, height: 1836),
               SystemProbe.virtualDisplayModeDimensions(
                   logicalWidth: 1470, logicalHeight: 918,
                   pixelWidth: 2940, pixelHeight: 1836,
                   usesPhysicalPixelMode: true))
        expect("Intel advertises the panel's logical workspace, not its native pixels",
               VirtualDisplayModeDimensions(width: 1792, height: 1120),
               SystemProbe.virtualDisplayModeDimensions(
                   logicalWidth: 1792, logicalHeight: 1120,
                   pixelWidth: 3072, pixelHeight: 1920,
                   usesPhysicalPixelMode: false))
        expect("invalid display geometry is refused",
               nil,
               SystemProbe.virtualDisplayModeDimensions(
                   logicalWidth: 0, logicalHeight: 1120,
                   pixelWidth: 3072, pixelHeight: 1920,
                   usesPhysicalPixelMode: false))

        print("\nSystemProbe.panelRestoreSchedule")
        expect("Intel virtual carrier waits while the lid is closed",
               PanelRestoreSchedule.waitForLidOpen,
               SystemProbe.panelRestoreSchedule(
                   isIntel: true, usesVirtualCarrier: true,
                   hasLid: true, lidClosed: true))
        expect("opening the Intel lid permits restore",
               PanelRestoreSchedule.now,
               SystemProbe.panelRestoreSchedule(
                   isIntel: true, usesVirtualCarrier: true,
                   hasLid: true, lidClosed: false))
        expect("Apple Silicon keeps its measured immediate restore path",
               PanelRestoreSchedule.now,
               SystemProbe.panelRestoreSchedule(
                   isIntel: false, usesVirtualCarrier: true,
                   hasLid: true, lidClosed: true))
        expect("dim mode has no virtual carrier to preserve",
               PanelRestoreSchedule.now,
               SystemProbe.panelRestoreSchedule(
                   isIntel: true, usesVirtualCarrier: false,
                   hasLid: true, lidClosed: true))

        print("\nSystemProbe.displayRescueCandidateIDs")
        let opaqueIntelID: UInt32 = 1_104_977_157
        let intelCandidates = SystemProbe.displayRescueCandidateIDs(
            builtinID: opaqueIntelID,
            legacyUpperBound: 32
        )
        expect("opaque Intel built-in ID is attempted first", opaqueIntelID,
               intelCandidates.first)
        expect("legacy fallback is retained", true,
               intelCandidates.contains(1) && intelCandidates.contains(32))
        expect("candidate list has no duplicate when built-in is a low ID", 32,
               SystemProbe.displayRescueCandidateIDs(
                   builtinID: 7, legacyUpperBound: 32
               ).count)

        print("\nDisplay restore marker")
        let displayMarker = SystemProbe.displayRestoreMarker(
            brightness: 0.5, virtualDisplayID: 1_104_977_157
        )
        expect("the extended marker preserves brightness", Float(0.5),
               SystemProbe.savedDisplayBrightness(in: displayMarker))
        expect("the extended marker carries the exact virtual ID", UInt32(1_104_977_157),
               SystemProbe.savedVirtualDisplayID(in: displayMarker))
        expect("old one-line markers remain valid", Float(0.5),
               SystemProbe.savedDisplayBrightness(in: "0.5\n"))
        expect("old markers safely have no virtual ID", nil,
               SystemProbe.savedVirtualDisplayID(in: "0.5\n"))
        expect("duplicate virtual IDs are rejected", nil,
               SystemProbe.savedVirtualDisplayID(in:
                   "0.5\nvirtualDisplayID=7\nvirtualDisplayID=8\n"))

        print("\nSystemProbe.panelBrightnessDecision (the one probe where unreadable PERMITS)")
        expect("a legible screen is left alone", PanelBrightnessDecision.leaveAlone,
               SystemProbe.panelBrightnessDecision(savedValue: 0.5, currentValue: 0.4))
        expect("exactly at the floor is legible", PanelBrightnessDecision.leaveAlone,
               SystemProbe.panelBrightnessDecision(savedValue: 0.5, currentValue: 0.02))
        expect("a dark screen gets the saved value back",
               PanelBrightnessDecision.restore(0.0625),
               SystemProbe.panelBrightnessDecision(savedValue: 0.0625, currentValue: 0.0))
        expect("an unreadable current value still permits the restore",
               PanelBrightnessDecision.restore(0.0625),
               SystemProbe.panelBrightnessDecision(savedValue: 0.0625, currentValue: nil))
        expect("a saved value that is itself dark falls back",
               PanelBrightnessDecision.restore(SystemProbe.panelFallbackBrightness),
               SystemProbe.panelBrightnessDecision(savedValue: 0.0, currentValue: 0.0))
        expect("no saved value falls back",
               PanelBrightnessDecision.restore(SystemProbe.panelFallbackBrightness),
               SystemProbe.panelBrightnessDecision(savedValue: nil, currentValue: 0.0))
        expect("an out-of-range saved value falls back",
               PanelBrightnessDecision.restore(SystemProbe.panelFallbackBrightness),
               SystemProbe.panelBrightnessDecision(savedValue: 2.0, currentValue: 0.0))
        expect("the dim level is below the visible floor, or recovery could never fire",
               true, SystemProbe.panelDimLevel < SystemProbe.panelVisibleFloor)
        expect("the fallback is above the visible floor", true,
               SystemProbe.panelFallbackBrightness > SystemProbe.panelVisibleFloor)

        // `Shell.collect` carries every probe in both binaries and had no test
        // of its own until 2026-08-02, when a review pass found three ways it
        // could hang or lie. Each of these covers one of them.
        print("\nShell.collect")
        let big = Shell.run("printf 'x%.0s' $(seq 1 200000)")
        // Output far past the 64 KB pipe buffer. Reading the pipe only after the
        // process exits deadlocks here: the child blocks writing, the parent
        // blocks waiting, and a healthy command becomes a timeout.
        expect("output larger than the pipe buffer is not truncated or deadlocked",
               200_000, big.output.count)
        expect("...and reports success", Int32(0), big.status)

        let slow = Shell.run(Shell.Command("/bin/sleep", ["30"]), timeout: 1)
        expect("a command past its deadline reports failure", Int32(-1), slow.status)

        // The one that actually catches the regression. `/bin/sleep` prints
        // nothing, so asserting an empty result from it passes just as well under
        // the old `(-1, partialOutput)` contract — this prints first and THEN
        // hangs, which is the shape of a truncated `ioreg`: half an answer that
        // used to be parsed as a whole one and could hold the panel dark.
        let partial = Shell.run("echo SENTINEL; sleep 30", timeout: 1)
        expect("a timeout after partial output reports failure", Int32(-1), partial.status)
        expect("...and hands back none of that partial output", "", partial.output)
        expect("...so Shell.output gives a parser nothing to believe",
               "", Shell.output("echo SENTINEL; sleep 30", timeout: 1))

        // A non-zero exit is NOT a timeout, and its output is still wanted: several
        // probes read the text of commands that fail on purpose.
        // Not named `failed`: that is the suite's own counter, and shadowing it
        // broke `exit(failed == 0 ...)` at the bottom of this function.
        let nonZero = Shell.run("echo kept; exit 3")
        expect("a genuine non-zero exit keeps its output", "kept", nonZero.output)
        expect("...and reports its real status", Int32(3), nonZero.status)

        let quick = Shell.run(Shell.Command("/bin/echo", ["still fine"]))
        expect("an ordinary command still works", "still fine", quick.output)

        // Two things had never been executed by a test until 2026-08-03: the
        // SIGKILL escalation, and the fate of a GRANDchild. One shape covers
        // both, and it has to be this shape.
        //
        // `trap '' TERM` is load-bearing, not decoration. Without it the escalation
        // never runs (every other child here dies on the SIGTERM before it), and —
        // measured against this exact code, both before and after the fix — a plain
        // `bash -c "echo X; sleep N"` leaves nothing behind either: bash signals its
        // own foreground job on the way out, so it cleans up its child for us and a
        // pid-only kill looks indistinguishable from a group kill. Ignoring TERM
        // forces SIGKILL to bash, which bash cannot forward, and only THEN does the
        // grandchild's fate depend on which of the two the code sends.
        //
        // That grandchild is the whole reason `collect` signals the process GROUP.
        // `sudo` — which every `Shell.runPrivileged*` path goes through — is the
        // tracked child, and the privileged command is one level below it. Before
        // the fix this exact case left `sleep` alive under launchd, holding the
        // pipe's write end, for its full duration.
        //
        // The odd duration is a marker, not a wait: nothing else sleeps for it, so
        // a match can only be this test's own orphan.
        let orphanSleep = "31.7"
        let escalationStarted = ContinuousClock.now
        let stubborn = Shell.run(
            Shell.Command("/bin/bash", ["-c", "trap '' TERM; echo SENTINEL; sleep \(orphanSleep)"]),
            timeout: 1
        )
        expect("a child that ignores SIGTERM still reports failure", Int32(-1), stubborn.status)
        // It comes back on the escalation's schedule, not the child's. Post-fix
        // this returns in ~2s (SIGKILL at the 1s timeout + 1s grace, then EOF
        // arrives at once because the grandchild died with the group). Pre-fix
        // it took ~5s: bash died on schedule but the orphaned grandchild held
        // the pipe open until the drain budget ran out. 4s sits between the two
        // with room for a loaded machine.
        expect("...and returns on the escalation's schedule, not the child's",
               true, escalationStarted.duration(to: .now) < .seconds(4))
        // Direct exec, not through a shell: `pgrep -f` would otherwise match the
        // /bin/bash -c carrying the same pattern in its own command line.
        let survivors = Shell.run(Shell.Command("/usr/bin/pgrep", ["-f", "sleep \(orphanSleep)"]))
        expect("...and its grandchild is not left running under launchd",
               "", survivors.output)

        print("\nSystemProbe.panelMode")
        expect("missing reads as the default", PanelMode.default,
               SystemProbe.panelMode(in: nil))
        expect("an unknown value reads as the default, it does not refuse",
               PanelMode.default, SystemProbe.panelMode(in: "sideways"))
        expect("empty reads as the default", PanelMode.default,
               SystemProbe.panelMode(in: ""))
        expect("virtual round-trips", PanelMode.virtualDisplay,
               SystemProbe.panelMode(in: "virtual"))
        expect("dim round-trips", PanelMode.dim, SystemProbe.panelMode(in: "dim"))
        expect("surrounding whitespace is tolerated, like every other state file",
               PanelMode.dim, SystemProbe.panelMode(in: "  dim\n"))
        // The mode that solves the stated problem is the one you get by default;
        // `.dim` is opt-in because it only makes the panel very dim, not dark.
        expect("the default is the virtual display", PanelMode.virtualDisplay,
               PanelMode.default)

        print("\nSystemProbe.markerBrightness (the lid-open sample beats the live read)")
        // The whole point: a reading taken once blackout is under way is a level
        // nobody chose, because macOS has already begun its lid-close fade.
        expect("a remembered lid-open value wins over the live reading",
               Float(0.56), SystemProbe.markerBrightness(lastOpenLid: 0.56, currentReading: 0.256))
        expect("with nothing remembered it falls back to the live reading",
               Float(0.256), SystemProbe.markerBrightness(lastOpenLid: nil, currentReading: 0.256))
        // Below the floor a remembered value is indistinguishable from one caught
        // mid-fade, so it is not trusted over a fresh read.
        expect("a remembered value below the visible floor is not trusted",
               Float(0.3), SystemProbe.markerBrightness(lastOpenLid: 0.01, currentReading: 0.3))
        expect("exactly at the floor is trusted", SystemProbe.panelVisibleFloor,
               SystemProbe.markerBrightness(lastOpenLid: SystemProbe.panelVisibleFloor,
                                            currentReading: 0.9))
        expect("an out-of-range remembered value falls back", Float(0.4),
               SystemProbe.markerBrightness(lastOpenLid: 2.0, currentReading: 0.4))
        expect("a non-finite remembered value falls back", Float(0.4),
               SystemProbe.markerBrightness(lastOpenLid: .infinity, currentReading: 0.4))
        expect("nothing readable at all is nil, and blackout refuses on it",
               true, SystemProbe.markerBrightness(lastOpenLid: nil, currentReading: nil) == nil)
        expect("an out-of-range live reading with nothing remembered is nil", true,
               SystemProbe.markerBrightness(lastOpenLid: nil, currentReading: 1.5) == nil)
        // Added because mutation showed the lower bound was pinned by nothing:
        // dropping `currentReading >= 0` passed the whole suite.
        expect("a negative live reading is nil, not a level to restore", true,
               SystemProbe.markerBrightness(lastOpenLid: nil, currentReading: -0.5) == nil)
        // A dark panel is a legitimate thing to remember coming back to; only the
        // REMEMBERED value is floor-gated, and only because of the fade.
        expect("a live reading below the floor is still used when it is all there is",
               Float(0.005), SystemProbe.markerBrightness(lastOpenLid: nil, currentReading: 0.005))

        print("\nSystemProbe.dimDecision (cannot blind the Mac, so it guards less)")
        expect("proceeds on an active built-in whose brightness can be driven",
               BlackoutDecision.proceed(builtinID: 1),
               SystemProbe.dimDecision(builtinID: 1, builtinActive: true,
                                       canChangeBrightness: true))
        expect("refuses without a built-in",
               BlackoutDecision.refuse(reason: "no built-in display was found"),
               SystemProbe.dimDecision(builtinID: nil, builtinActive: true,
                                       canChangeBrightness: true))
        expect("refuses when the built-in is not active",
               BlackoutDecision.refuse(reason: "the built-in display is not active to begin with"),
               SystemProbe.dimDecision(builtinID: 1, builtinActive: false,
                                       canChangeBrightness: true))
        // Unreadable is not active. Dimming a display that may already be asleep
        // would write a level nobody asked for and nothing would undo it.
        expect("refuses when the active list could not be read",
               BlackoutDecision.refuse(reason: "the built-in display is not active to begin with"),
               SystemProbe.dimDecision(builtinID: 1, builtinActive: nil,
                                       canChangeBrightness: true))
        expect("refuses when brightness cannot be driven — the write IS the feature",
               BlackoutDecision.refuse(reason: "this Mac does not allow the panel's brightness to be set"),
               SystemProbe.dimDecision(builtinID: 1, builtinActive: true,
                                       canChangeBrightness: false))

        print("\nSystemProbe.panelPresentation — shapes left by .virtualDisplay")
        expect("lit", PanelPresentation.lit,
               SystemProbe.panelPresentation(builtinActive: true, brightness: 0.5,
                                             blackoutOwnedByThisApp: false))
        expect("dark while this app owns it", PanelPresentation.dark,
               SystemProbe.panelPresentation(builtinActive: false, brightness: 0.0,
                                             blackoutOwnedByThisApp: true))
        expect("stranded when nobody owns it", PanelPresentation.stranded,
               SystemProbe.panelPresentation(builtinActive: false, brightness: 0.0,
                                             blackoutOwnedByThisApp: false))
        expect("an unreadable display list is unknown, not lit", PanelPresentation.unknown,
               SystemProbe.panelPresentation(builtinActive: nil, brightness: 0.5,
                                             blackoutOwnedByThisApp: false))
        expect("active but dimmed and unowned is stranded, not lit", PanelPresentation.stranded,
               SystemProbe.panelPresentation(builtinActive: true, brightness: 0.0,
                                             blackoutOwnedByThisApp: false))
        // An unreadable brightness is not evidence of a dark screen — but it is not
        // evidence of a lit one either. Both of these used to assert `.lit`, which
        // was a confident answer built on a probe that returned nothing. The bug
        // that rule was guarding against was `.stranded`, the red one; `.unknown`
        // is amber, and only while blackout is armed.
        expect("active with an unreadable brightness is unknown, not lit",
               PanelPresentation.unknown,
               SystemProbe.panelPresentation(builtinActive: true, brightness: nil,
                                             blackoutOwnedByThisApp: false))
        expect("...and the same while this app owns the blackout",
               PanelPresentation.unknown,
               SystemProbe.panelPresentation(builtinActive: true, brightness: nil,
                                             blackoutOwnedByThisApp: true))
        // The lapse signal must survive that change: a `.virtualDisplay` blackout
        // that handed the panel back reads bright, and reconcile keys on it.
        expect("active, ours and readably bright is still lit", PanelPresentation.lit,
               SystemProbe.panelPresentation(builtinActive: true, brightness: 0.5,
                                             blackoutOwnedByThisApp: true))
        expect("a disabled panel is still dark when this app owns it", PanelPresentation.dark,
               SystemProbe.panelPresentation(builtinActive: false, brightness: nil,
                                             blackoutOwnedByThisApp: true))

        print("\nSystemProbe.panelPresentation — shapes left by .dim, where the panel stays ACTIVE")
        // `.dim` leaves the built-in ACTIVE while blackout is in effect, which is
        // the opposite of the shape above. These cases exist because that looked
        // like it needed a `mode:` parameter — it does not, and mutation testing
        // proved the added branch changed no answer. Keeping them pins the claim
        // that one function covers both modes, so the parameter does not come back.
        expect("active and dimmed while this app owns it is dark, not lit",
               PanelPresentation.dark,
               SystemProbe.panelPresentation(builtinActive: true,
                                             brightness: SystemProbe.panelDimLevel,
                                             blackoutOwnedByThisApp: true))
        expect("active and dimmed with nobody owning it is stranded",
               PanelPresentation.stranded,
               SystemProbe.panelPresentation(builtinActive: true,
                                             brightness: SystemProbe.panelDimLevel,
                                             blackoutOwnedByThisApp: false))
        expect("a bright panel is lit even while this app owns the blackout",
               PanelPresentation.lit,
               SystemProbe.panelPresentation(builtinActive: true, brightness: 0.5,
                                             blackoutOwnedByThisApp: true))
        // Brightness is the only evidence this mode has, so an unreadable probe
        // resolves to `.unknown`: not a warning, and not a clean bill of health
        // either. It used to assert `.lit` to avoid the red `.stranded` card, but
        // `.unknown` is not that card — it is amber, and only while blackout is
        // armed, which a Mac with an unreadable brightness getter can never be.
        expect("an unreadable brightness is unknown, not stranded and not lit",
               PanelPresentation.unknown,
               SystemProbe.panelPresentation(builtinActive: true, brightness: nil,
                                             blackoutOwnedByThisApp: false))
        expect("an unreadable display list is still unknown", PanelPresentation.unknown,
               SystemProbe.panelPresentation(builtinActive: nil, brightness: 0.0,
                                             blackoutOwnedByThisApp: true))
        expect("exactly at the visible floor is lit, not dark", PanelPresentation.lit,
               SystemProbe.panelPresentation(builtinActive: true,
                                             brightness: SystemProbe.panelVisibleFloor,
                                             blackoutOwnedByThisApp: true))

        // Phase 2 (docs/ARCHITECTURE.md) — lifecycle decisions extracted
        // from Sources/main.swift's Lidless controller, pure functions here for
        // the first time.
        print("\nSystemProbe.panelCarrierVerdict")
        expect("no carrier at all is gone (.dim never creates one)",
               CarrierState.gone,
               SystemProbe.panelCarrierVerdict(carrier: nil, activeDisplayIDs: [1, 2]))
        expect("a terminated carrier is gone regardless of the active list",
               CarrierState.gone,
               SystemProbe.panelCarrierVerdict(carrier: (terminated: true, displayID: 7),
                                               activeDisplayIDs: [7]))
        // round 9 (fixes-0802.md): collapsing an unreadable active list into
        // "gone" tore down a working blackout on one transient probe failure —
        // three answers, not two, is the whole point of this type.
        expect("an unreadable active list is unknown, not gone",
               CarrierState.unknown,
               SystemProbe.panelCarrierVerdict(carrier: (terminated: false, displayID: 7),
                                               activeDisplayIDs: nil))
        expect("the carrier's own id present in the active list is alive",
               CarrierState.alive,
               SystemProbe.panelCarrierVerdict(carrier: (terminated: false, displayID: 7),
                                               activeDisplayIDs: [1, 7, 3]))
        expect("a readable active list missing the carrier's id is gone",
               CarrierState.gone,
               SystemProbe.panelCarrierVerdict(carrier: (terminated: false, displayID: 7),
                                               activeDisplayIDs: [1, 3]))
        expect("an empty (but readable) active list is gone, not unknown",
               CarrierState.gone,
               SystemProbe.panelCarrierVerdict(carrier: (terminated: false, displayID: 7),
                                               activeDisplayIDs: []))
        // D2 (docs/ARCHITECTURE.md). Display sleep empties the
        // active list of EVERY display, the carrier included, and the carrier
        // comes back on wake with its termination callback never having fired —
        // measured 2026-08-04. Reading that emptiness as "gone" is what cost a
        // night of tear-down-and-rebuild.
        expect("the carrier missing while the display domain sleeps is asleep, not gone",
               CarrierState.asleep,
               SystemProbe.panelCarrierVerdict(carrier: (terminated: false, displayID: 7),
                                               activeDisplayIDs: [1, 3],
                                               displayAsleep: true))
        expect("...and an empty list during display sleep is asleep too",
               CarrierState.asleep,
               SystemProbe.panelCarrierVerdict(carrier: (terminated: false, displayID: 7),
                                               activeDisplayIDs: [],
                                               displayAsleep: true))
        // The one that must NOT be softened: a destroyed display is destroyed
        // whatever the domain is doing, or "asleep" becomes a way to sit still
        // while nothing can ever display anything again.
        expect("a TERMINATED carrier is still gone even while the domain sleeps",
               CarrierState.gone,
               SystemProbe.panelCarrierVerdict(carrier: (terminated: true, displayID: 7),
                                               activeDisplayIDs: [],
                                               displayAsleep: true))
        expect("...and a carrier still in the list is alive, asleep flag or not",
               CarrierState.alive,
               SystemProbe.panelCarrierVerdict(carrier: (terminated: false, displayID: 7),
                                               activeDisplayIDs: [7],
                                               displayAsleep: true))
        expect("...while an unreadable list stays unknown, not asleep",
               CarrierState.unknown,
               SystemProbe.panelCarrierVerdict(carrier: (terminated: false, displayID: 7),
                                               activeDisplayIDs: nil,
                                               displayAsleep: true))
        expect("the default keeps every existing caller's meaning (domain awake)",
               CarrierState.gone,
               SystemProbe.panelCarrierVerdict(carrier: (terminated: false, displayID: 7),
                                               activeDisplayIDs: []))

        print("\nSystemProbe.panelRecoveryIsAutomaticDecision")
        expect("an unconfirmed restore is never automatic, regardless of anything else",
               false,
               SystemProbe.panelRecoveryIsAutomaticDecision(
                   restoreUnconfirmed: true, ownedByThisApp: true,
                   presentation: .lit, watchdogRunning: true,
                   attempts: 0, attemptCap: 30))
        // round 5 (fixes-0802.md): a .dim that lapsed on a Mac with an
        // unreadable brightness getter can never be detected or re-applied, so
        // this is not automatic recovery even though the watchdog is fine.
        expect("owning the panel with an unreadable presentation is not automatic",
               false,
               SystemProbe.panelRecoveryIsAutomaticDecision(
                   restoreUnconfirmed: false, ownedByThisApp: true,
                   presentation: .unknown, watchdogRunning: true,
                   attempts: 0, attemptCap: 30))
        expect("an unreadable presentation for a panel we do NOT own does not gate it",
               true,
               SystemProbe.panelRecoveryIsAutomaticDecision(
                   restoreUnconfirmed: false, ownedByThisApp: false,
                   presentation: .unknown, watchdogRunning: true,
                   attempts: 0, attemptCap: 30))
        expect("no watchdog is not automatic",
               false,
               SystemProbe.panelRecoveryIsAutomaticDecision(
                   restoreUnconfirmed: false, ownedByThisApp: true,
                   presentation: .lit, watchdogRunning: false,
                   attempts: 0, attemptCap: 30))
        expect("attempts at the cap is not automatic",
               false,
               SystemProbe.panelRecoveryIsAutomaticDecision(
                   restoreUnconfirmed: false, ownedByThisApp: true,
                   presentation: .lit, watchdogRunning: true,
                   attempts: 30, attemptCap: 30))
        expect("a healthy hold with budget left is automatic",
               true,
               SystemProbe.panelRecoveryIsAutomaticDecision(
                   restoreUnconfirmed: false, ownedByThisApp: true,
                   presentation: .lit, watchdogRunning: true,
                   attempts: 29, attemptCap: 30))

        print("\nSystemProbe.blackoutRollbackDecision")
        // round 9 (fixes-0802.md): an unconditional rollback tore down the
        // safety nets inherited from an unconfirmed restore — the worst state
        // this feature can reach, since nothing then tries again.
        expect("an unconfirmed restore keeps the inherited nets",
               false, SystemProbe.blackoutRollbackDecision(restoreUnconfirmed: true))
        expect("a confirmed (or no prior) restore tears down this attempt's own nets",
               true, SystemProbe.blackoutRollbackDecision(restoreUnconfirmed: false))

        print("\nSystemProbe.markerInheritDecision")
        expect("no unconfirmed restore in progress: always write a fresh marker",
               true, SystemProbe.markerInheritDecision(restoreUnconfirmed: false, savedReadable: true))
        expect("no unconfirmed restore, nothing saved either: still write fresh",
               true, SystemProbe.markerInheritDecision(restoreUnconfirmed: false, savedReadable: false))
        // round 10 (fixes-0802.md): the condition used to check `fileExists`, not
        // readability — a corrupt marker was preserved over a fresh, available
        // value, and the restore then fell back to a default instead of the
        // level actually recorded.
        expect("unconfirmed restore with a readable saved marker: keep the old one, do not write",
               false, SystemProbe.markerInheritDecision(restoreUnconfirmed: true, savedReadable: true))
        expect("unconfirmed restore but the saved marker is not readable: write fresh anyway",
               true, SystemProbe.markerInheritDecision(restoreUnconfirmed: true, savedReadable: false))

        // D3 (docs/ARCHITECTURE.md). Eight teardowns of a
        // working blackout on the night of 2026-08-03/04 came from single bad
        // probe readings, every one contradicted by the next refresh.
        print("\nSystemProbe.panelGoalDeferralDecision")
        func defer_(_ current: PanelGoal, _ proposed: PanelGoal,
                    watchdogLost: Bool = false, sessionDisplayLost: Bool = false,
                    isFullyOn: Bool = true, hasLid: Bool = true, lidClosed: Bool = true,
                    alreadyDeferred: Bool = false) -> Bool {
            SystemProbe.panelGoalDeferralDecision(
                currentGoal: current, proposedGoal: proposed,
                watchdogLost: watchdogLost, sessionDisplayLost: sessionDisplayLost,
                isFullyOn: isFullyOn, hasLid: hasLid, lidClosed: lidClosed,
                alreadyDeferred: alreadyDeferred)
        }
        // The real lid opening. Must NOT be delayed — it is the normal path and
        // the P0 runbook measures it at ~3 s end to end.
        expect("a positive reading of an open lid is acted on at once",
               false, defer_(.dark, .lit, hasLid: true, lidClosed: false))
        // The two shapes that actually caused the churn.
        expect("the clamshell key going missing is deferred one round",
               true, defer_(.dark, .lit, hasLid: false, lidClosed: false))
        expect("Lidless reading as off with the lid still shut is deferred one round",
               true, defer_(.dark, .lit, isFullyOn: false))
        // Strictly one round: the safe direction is postponed, never denied.
        expect("...but only once — a second consecutive reading is believed",
               false, defer_(.dark, .lit, hasLid: false, alreadyDeferred: true))
        expect("...and the same for the isFullyOn shape",
               false, defer_(.dark, .lit, isFullyOn: false, alreadyDeferred: true))
        // Never delay going dark, and never delay a goal that is not changing.
        expect("going dark is never deferred",
               false, defer_(.lit, .dark, hasLid: false))
        expect("a goal that already matches is not a change to defer",
               false, defer_(.dark, .dark, hasLid: false))
        // The two safety conditions. Both arrive with the lid shut, so the
        // absence test would have swallowed them; deferring the restore that
        // exists because the way back is gone is the one unacceptable outcome.
        expect("a lost watchdog is never deferred, lid shut or not",
               false, defer_(.dark, .lit, watchdogLost: true))
        expect("a lost session display is never deferred",
               false, defer_(.dark, .lit, sessionDisplayLost: true))

        print("\nSystemProbe.panelCarrierPresumedGoneDecision")
        let carrierNow: ContinuousClock.Instant = .now
        let recentlyUnknown: ContinuousClock.Instant = carrierNow.advanced(by: .seconds(-10))
        let longUnknown: ContinuousClock.Instant = carrierNow.advanced(by: .seconds(-40))
        // round 13 (fixes-0802.md): outside .virtualDisplay there is no carrier by
        // construction, so a verdict of .gone is meaningless — without this gate
        // the one-second lid watch fired a full system probe every second for the
        // whole length of a .dim.
        expect(".dim never has a carrier, so this is always false regardless of state",
               false,
               SystemProbe.panelCarrierPresumedGoneDecision(
                   heldMode: .dim, carrierSnapshot: .gone, unknownSince: nil,
                   now: carrierNow, unknownGraceSeconds: 30))
        expect("held as .virtualDisplay and confirmed gone",
               true,
               SystemProbe.panelCarrierPresumedGoneDecision(
                   heldMode: .virtualDisplay, carrierSnapshot: .gone, unknownSince: nil,
                   now: carrierNow, unknownGraceSeconds: 30))
        expect("held as .virtualDisplay and confirmed alive is never presumed gone",
               false,
               SystemProbe.panelCarrierPresumedGoneDecision(
                   heldMode: .virtualDisplay, carrierSnapshot: .alive, unknownSince: recentlyUnknown,
                   now: carrierNow, unknownGraceSeconds: 30))
        // D2. The whole point of the new case: the display domain sleeping is the
        // blackout SUCCEEDING — the panel is dark — so it must never start a
        // restore. And it must not age out through the grace period either, no
        // matter how long the Mac sits asleep, which is why it is answered before
        // `unknownSince` is ever consulted.
        expect("a carrier asleep with the display domain is not presumed gone",
               false,
               SystemProbe.panelCarrierPresumedGoneDecision(
                   heldMode: .virtualDisplay, carrierSnapshot: .asleep, unknownSince: nil,
                   now: carrierNow, unknownGraceSeconds: 30))
        expect("...and stays that way however long it has been down",
               false,
               SystemProbe.panelCarrierPresumedGoneDecision(
                   heldMode: .virtualDisplay, carrierSnapshot: .asleep, unknownSince: longUnknown,
                   now: carrierNow, unknownGraceSeconds: 30))
        expect("unknown with no start time recorded is not yet presumed gone",
               false,
               SystemProbe.panelCarrierPresumedGoneDecision(
                   heldMode: .virtualDisplay, carrierSnapshot: .unknown, unknownSince: nil,
                   now: carrierNow, unknownGraceSeconds: 30))
        expect("unknown for less than the grace period is not yet presumed gone",
               false,
               SystemProbe.panelCarrierPresumedGoneDecision(
                   heldMode: .virtualDisplay, carrierSnapshot: .unknown, unknownSince: recentlyUnknown,
                   now: carrierNow, unknownGraceSeconds: 30))
        expect("unknown past the grace period is presumed gone",
               true,
               SystemProbe.panelCarrierPresumedGoneDecision(
                   heldMode: .virtualDisplay, carrierSnapshot: .unknown, unknownSince: longUnknown,
                   now: carrierNow, unknownGraceSeconds: 30))
        // round 11 (fixes-0802.md): the clock must only count while the CURRENT
        // reading is still .unknown — an .alive verdict here must not be overruled
        // by how long a PRIOR unknown streak had lasted, or a probe that recovered
        // tears down a working blackout for nothing. `carrierSnapshot: .alive`
        // above already pins this; this case pins the .gone side of the same rule.
        expect("a confirmed .gone verdict does not consult the stale clock at all",
               true,
               SystemProbe.panelCarrierPresumedGoneDecision(
                   heldMode: .virtualDisplay, carrierSnapshot: .gone, unknownSince: recentlyUnknown,
                   now: carrierNow, unknownGraceSeconds: 30))

        print("\nSystemProbe.panelGoalDecision")
        // round 2 (fixes-0802.md): watchdogLost used to call restorePanel()
        // directly, out of band — skipping the attempt counter and backoff, so a
        // restore that kept failing looped forever. Folded into "not armed" here.
        expect("a lost watchdog is never armed, regardless of everything else",
               PanelGoal.lit,
               SystemProbe.panelGoalDecision(watchdogLost: true, sessionDisplayLost: false,
                                             blackoutEnabled: true, isFullyOn: true,
                                             hasLid: true, lidClosed: true))
        // round 5 (fixes-0802.md): the carrier vanishing while the built-in stays
        // off left nothing showing anything — same treatment as a lost watchdog.
        expect("a lost session display is never armed, regardless of everything else",
               PanelGoal.lit,
               SystemProbe.panelGoalDecision(watchdogLost: false, sessionDisplayLost: true,
                                             blackoutEnabled: true, isFullyOn: true,
                                             hasLid: true, lidClosed: true))
        expect("blackout disabled in settings is not armed",
               PanelGoal.lit,
               SystemProbe.panelGoalDecision(watchdogLost: false, sessionDisplayLost: false,
                                             blackoutEnabled: false, isFullyOn: true,
                                             hasLid: true, lidClosed: true))
        expect("not fully on is not armed",
               PanelGoal.lit,
               SystemProbe.panelGoalDecision(watchdogLost: false, sessionDisplayLost: false,
                                             blackoutEnabled: true, isFullyOn: false,
                                             hasLid: true, lidClosed: true))
        // An unreadable lid probe defaults hasLid/lidClosed to false upstream —
        // failing towards a visible screen, not towards blacking one out.
        expect("no lid (desktop, or unreadable probe) is not armed",
               PanelGoal.lit,
               SystemProbe.panelGoalDecision(watchdogLost: false, sessionDisplayLost: false,
                                             blackoutEnabled: true, isFullyOn: true,
                                             hasLid: false, lidClosed: true))
        expect("lid open is not armed",
               PanelGoal.lit,
               SystemProbe.panelGoalDecision(watchdogLost: false, sessionDisplayLost: false,
                                             blackoutEnabled: true, isFullyOn: true,
                                             hasLid: true, lidClosed: false))
        expect("everything satisfied is armed: dark",
               PanelGoal.dark,
               SystemProbe.panelGoalDecision(watchdogLost: false, sessionDisplayLost: false,
                                             blackoutEnabled: true, isFullyOn: true,
                                             hasLid: true, lidClosed: true))

        print("\nSystemProbe.attemptForgivenessDecision")
        // round 13 (fixes-0802.md): forgiveness used to be granted in a branch
        // that never actually finished removing the marker — handing out a fresh
        // attempt budget on every pass through it, forever.
        expect("marker still present: not forgiven, keep counting against the budget",
               false, SystemProbe.attemptForgivenessDecision(markerStillPresent: true))
        expect("marker genuinely gone: forgiven, reset the budget",
               true, SystemProbe.attemptForgivenessDecision(markerStillPresent: false))

        print("\nSystemProbe.panelAttemptDecision")
        let attemptNow: ContinuousClock.Instant = .now
        let dueInFuture: ContinuousClock.Instant = attemptNow.advanced(by: .seconds(5))
        let alreadyDue: ContinuousClock.Instant = attemptNow.advanced(by: .seconds(-5))
        expect("still backing off: wait, with budget to spare",
               PanelAttemptVerdict.wait,
               SystemProbe.panelAttemptDecision(
                   now: attemptNow, nextAttempt: dueInFuture, attempts: 0, attemptCap: 30,
                   goal: .dark, hasPanelToRestore: false, gaveUpReported: false,
                   backoffStep: 2, backoffCeiling: 15))
        // The wait check runs BEFORE the cap check — even with the budget spent,
        // still-backing-off answers .wait, not .capReached. The gave-up
        // message/escalation must not fire until the backoff window elapses.
        expect("still backing off wins over a spent budget: wait, not capReached",
               PanelAttemptVerdict.wait,
               SystemProbe.panelAttemptDecision(
                   now: attemptNow, nextAttempt: dueInFuture, attempts: 30, attemptCap: 30,
                   goal: .lit, hasPanelToRestore: true, gaveUpReported: false,
                   backoffStep: 2, backoffCeiling: 15))
        // round 18 (fixes-0802.md): escalation goes through the bounded rescue
        // tool directly, not by feigning a dead heartbeat — the message and the
        // escalation are two separate flags for exactly this case.
        expect("cap reached, .lit with something to restore: message AND escalate",
               PanelAttemptVerdict.capReached(showMessage: true, shouldEscalate: true),
               SystemProbe.panelAttemptDecision(
                   now: attemptNow, nextAttempt: alreadyDue, attempts: 30, attemptCap: 30,
                   goal: .lit, hasPanelToRestore: true, gaveUpReported: false,
                   backoffStep: 2, backoffCeiling: 15))
        expect("cap reached, .dark goal: message but no escalation (nothing to hand over to)",
               PanelAttemptVerdict.capReached(showMessage: true, shouldEscalate: false),
               SystemProbe.panelAttemptDecision(
                   now: attemptNow, nextAttempt: alreadyDue, attempts: 30, attemptCap: 30,
                   goal: .dark, hasPanelToRestore: false, gaveUpReported: false,
                   backoffStep: 2, backoffCeiling: 15))
        expect("cap reached, .lit but nothing to restore: message but no escalation",
               PanelAttemptVerdict.capReached(showMessage: true, shouldEscalate: false),
               SystemProbe.panelAttemptDecision(
                   now: attemptNow, nextAttempt: alreadyDue, attempts: 30, attemptCap: 30,
                   goal: .lit, hasPanelToRestore: false, gaveUpReported: false,
                   backoffStep: 2, backoffCeiling: 15))
        expect("cap reached, already reported: neither message nor escalation repeat",
               PanelAttemptVerdict.capReached(showMessage: false, shouldEscalate: false),
               SystemProbe.panelAttemptDecision(
                   now: attemptNow, nextAttempt: alreadyDue, attempts: 30, attemptCap: 30,
                   goal: .lit, hasPanelToRestore: true, gaveUpReported: true,
                   backoffStep: 2, backoffCeiling: 15))
        // Backoff uses the POST-increment count (attempts + 1). This case pins
        // that specifically: at attempts=0 the pre-increment formula would give
        // min(0 * 2, 15) = 0, an un-delayed retry; the correct answer uses
        // nextCount=1, min(1 * 2, 15) = 2.
        expect("proceeding from 0 attempts backs off by ONE step, not zero",
               PanelAttemptVerdict.proceed(nextAttempt: attemptNow.advanced(by: .seconds(2))),
               SystemProbe.panelAttemptDecision(
                   now: attemptNow, nextAttempt: alreadyDue, attempts: 0, attemptCap: 30,
                   goal: .dark, hasPanelToRestore: false, gaveUpReported: false,
                   backoffStep: 2, backoffCeiling: 15))
        expect("backoff grows with the post-increment attempt count, under the ceiling",
               PanelAttemptVerdict.proceed(nextAttempt: attemptNow.advanced(by: .seconds(10))),
               SystemProbe.panelAttemptDecision(
                   now: attemptNow, nextAttempt: alreadyDue, attempts: 4, attemptCap: 30,
                   goal: .dark, hasPanelToRestore: false, gaveUpReported: false,
                   backoffStep: 2, backoffCeiling: 15))
        expect("backoff clamps at the ceiling",
               PanelAttemptVerdict.proceed(nextAttempt: attemptNow.advanced(by: .seconds(15))),
               SystemProbe.panelAttemptDecision(
                   now: attemptNow, nextAttempt: alreadyDue, attempts: 10, attemptCap: 30,
                   goal: .dark, hasPanelToRestore: false, gaveUpReported: false,
                   backoffStep: 2, backoffCeiling: 15))

        print("\nSystemProbe.virtualDisplayChurnDecision")
        let churnNow = Date(timeIntervalSince1970: 1_000_000)
        let churnMonotonicNow: ContinuousClock.Instant = .now
        expect("empty history, nothing monotonic recorded: proceed",
               ChurnResult(prunedHistory: [], outcome: .proceed),
               SystemProbe.virtualDisplayChurnDecision(
                   history: [], now: churnNow, lastMonotonic: nil, nowMonotonic: churnMonotonicNow,
                   reapplyFloor: 10, churnWindow: 300, churnLimit: 6))
        expect("last build too recent (calendar floor): rate limited",
               ChurnResult(prunedHistory: [churnNow.addingTimeInterval(-5)], outcome: .rateLimited),
               SystemProbe.virtualDisplayChurnDecision(
                   history: [churnNow.addingTimeInterval(-5)], now: churnNow,
                   lastMonotonic: nil, nowMonotonic: churnMonotonicNow,
                   reapplyFloor: 10, churnWindow: 300, churnLimit: 6))
        expect("calendar floor satisfied but the monotonic companion disagrees: rate limited",
               ChurnResult(prunedHistory: [churnNow.addingTimeInterval(-20)], outcome: .rateLimited),
               SystemProbe.virtualDisplayChurnDecision(
                   history: [churnNow.addingTimeInterval(-20)], now: churnNow,
                   lastMonotonic: churnMonotonicNow, nowMonotonic: churnMonotonicNow.advanced(by: .seconds(5)),
                   reapplyFloor: 10, churnWindow: 300, churnLimit: 6))
        expect("both clocks past the floor: proceed",
               ChurnResult(prunedHistory: [churnNow.addingTimeInterval(-20)], outcome: .proceed),
               SystemProbe.virtualDisplayChurnDecision(
                   history: [churnNow.addingTimeInterval(-20)], now: churnNow,
                   lastMonotonic: churnMonotonicNow, nowMonotonic: churnMonotonicNow.advanced(by: .seconds(20)),
                   reapplyFloor: 10, churnWindow: 300, churnLimit: 6))
        // Entries outside the window are dropped from prunedHistory before any
        // other check runs — a stale entry must not be able to block the floor
        // or count against the ceiling.
        expect("an entry outside the churn window is pruned before anything else",
               ChurnResult(prunedHistory: [churnNow.addingTimeInterval(-100)], outcome: .proceed),
               SystemProbe.virtualDisplayChurnDecision(
                   history: [churnNow.addingTimeInterval(-400), churnNow.addingTimeInterval(-100)],
                   now: churnNow, lastMonotonic: nil, nowMonotonic: churnMonotonicNow,
                   reapplyFloor: 10, churnWindow: 300, churnLimit: 6))
        expect("one under the ceiling: proceed",
               ChurnResult(prunedHistory: Array(repeating: churnNow.addingTimeInterval(-200), count: 5),
                           outcome: .proceed),
               SystemProbe.virtualDisplayChurnDecision(
                   history: Array(repeating: churnNow.addingTimeInterval(-200), count: 5),
                   now: churnNow, lastMonotonic: nil, nowMonotonic: churnMonotonicNow,
                   reapplyFloor: 10, churnWindow: 300, churnLimit: 6))
        expect("exactly at the ceiling: ceilingReached, not proceed",
               ChurnResult(prunedHistory: Array(repeating: churnNow.addingTimeInterval(-200), count: 6),
                           outcome: .ceilingReached),
               SystemProbe.virtualDisplayChurnDecision(
                   history: Array(repeating: churnNow.addingTimeInterval(-200), count: 6),
                   now: churnNow, lastMonotonic: nil, nowMonotonic: churnMonotonicNow,
                   reapplyFloor: 10, churnWindow: 300, churnLimit: 6))
        // round 13 (fixes-0802.md): the floor used to read `history.last`, and
        // the history was not sorted — an out-of-order array let a stale
        // "newest" entry through on the first comparison and the brake did
        // nothing. `.max()` must be used regardless of input order.
        expect("floor check uses .max(), not .last — out-of-order input still rate limits correctly",
               ChurnResult(prunedHistory: [churnNow.addingTimeInterval(-5), churnNow.addingTimeInterval(-200)],
                           outcome: .rateLimited),
               SystemProbe.virtualDisplayChurnDecision(
                   history: [churnNow.addingTimeInterval(-5), churnNow.addingTimeInterval(-200)],
                   now: churnNow, lastMonotonic: nil, nowMonotonic: churnMonotonicNow,
                   reapplyFloor: 10, churnWindow: 300, churnLimit: 6))

        // SMC decoder (Sources/SMCSensors.swift).
        //
        // Deviation from the rest of this file, deliberate: these fixtures are
        // inline byte arrays rather than files under tests/fixtures/. An SMC
        // response is four bytes; a binary fixture file would be unreviewable
        // in a diff, unlike the text fixtures the other cases use. Do not
        // "fix" this by moving them out.
        //
        // Every byte array below is little-endian, which is the measured byte
        // order for `flt ` — see docs/SMC_SENSORS.md §1.
        print("\nSMCDecode.watts")
        // The golden value: 21.15 W, the figure measured under CPU load in
        // docs/SMC_SENSORS.md §2. Compared as a formatted string because
        // Float cannot hold 21.15 exactly and an == on the Double would be a
        // test of binary32 rounding, not of the decoder.
        expect("golden 21.15 W decodes", "21.15",
               SMCDecode.watts(SMCKeyValue(type: "flt ", bytes: [0x33, 0x33, 0xA9, 0x41]))
                   .map { String(format: "%.2f", $0) })
        expect("exactly zero watts is no-data, not 0 W", Double?.none,
               SMCDecode.watts(SMCKeyValue(type: "flt ", bytes: [0x00, 0x00, 0x00, 0x00])))
        expect("an integer type is never reinterpreted", Double?.none,
               SMCDecode.watts(SMCKeyValue(type: "ui16", bytes: [0x33, 0x33, 0xA9, 0x41])))
        expect("a declared size that disagrees with the type is refused", Double?.none,
               SMCDecode.watts(SMCKeyValue(type: "flt ", size: 2, bytes: [0x33, 0x33, 0xA9, 0x41])))
        expect("short data is refused", Double?.none,
               SMCDecode.watts(SMCKeyValue(type: "flt ", bytes: [0x33, 0x33])))
        expect("NaN is refused", Double?.none,
               SMCDecode.watts(SMCKeyValue(type: "flt ", bytes: [0x00, 0x00, 0xC0, 0x7F])))
        expect("infinity is refused", Double?.none,
               SMCDecode.watts(SMCKeyValue(type: "flt ", bytes: [0x00, 0x00, 0x80, 0x7F])))

        print("\nSMCDecode.celsius")
        expect("62.6 °C decodes", "62.60",
               SMCDecode.celsius(SMCKeyValue(type: "flt ", bytes: [0x66, 0x66, 0x7A, 0x42]))
                   .map { String(format: "%.2f", $0) })
        // 112.8 °C was the measured peak with Low Power Mode off (spec §5), so
        // the plausible ceiling must not reject it.
        expect("the measured peak of 112.8 °C is still plausible", "112.80",
               SMCDecode.celsius(SMCKeyValue(type: "flt ", bytes: [0x9A, 0x99, 0xE1, 0x42]))
                   .map { String(format: "%.2f", $0) })
        expect("500 °C is refused", Double?.none,
               SMCDecode.celsius(SMCKeyValue(type: "flt ", bytes: [0x00, 0x00, 0xFA, 0x43])))
        expect("−40 °C is refused", Double?.none,
               SMCDecode.celsius(SMCKeyValue(type: "flt ", bytes: [0x00, 0x00, 0x20, 0xC2])))
        expect("a 0 °C die is a bad decode, not a cold part", Double?.none,
               SMCDecode.celsius(SMCKeyValue(type: "flt ", bytes: [0x00, 0x00, 0x00, 0x00])))
        expect("Intel sp78 62.5 °C decodes", 62.5,
               SMCDecode.celsius(SMCKeyValue(type: "sp78", bytes: [0x3E, 0x80])))
        expect("Intel sp78 negative temperatures are refused", Double?.none,
               SMCDecode.celsius(SMCKeyValue(type: "sp78", bytes: [0xFF, 0x00])))
        expect("Intel sp78 with the wrong length is refused", Double?.none,
               SMCDecode.celsius(SMCKeyValue(type: "sp78", bytes: [0x3E])))

        print("\nSMCDecode.rpm")
        expect("1840 rpm decodes", 1840.0,
               SMCDecode.rpm(SMCKeyValue(type: "flt ", bytes: [0x00, 0x00, 0xE6, 0x44])))
        expect("zero rpm is a stopped fan, not no-data", Double?.some(0),
               SMCDecode.rpm(SMCKeyValue(type: "flt ", bytes: [0x00, 0x00, 0x00, 0x00])))
        expect("Intel fpe2 1840 rpm decodes", 1840.0,
               SMCDecode.rpm(SMCKeyValue(type: "fpe2", bytes: [0x1C, 0xC0])))
        // `sp78` has three decode tests; its fpe2 sibling had one. These are the
        // guards, and the ceiling is now the ONLY one left: 17a976e widened
        // plausibleRPM from 1...12000 to 0...12000, so a stopped fan reads as a
        // real zero and nothing else stands between a garbage value and the UI.
        expect("a wrong-length fpe2 value is refused", Double?.none,
               SMCDecode.rpm(SMCKeyValue(type: "fpe2", bytes: [0x1C])))
        expect("a type this decoder does not know is refused, not guessed at", Double?.none,
               SMCDecode.rpm(SMCKeyValue(type: "ui16", bytes: [0x1C, 0xC0])))
        expect("zero rpm is a real reading — a stopped fan, not a failure", 0.0,
               SMCDecode.rpm(SMCKeyValue(type: "fpe2", bytes: [0x00, 0x00])))
        expect("past the 12000 rpm ceiling is refused (fpe2)", Double?.none,
               SMCDecode.rpm(SMCKeyValue(type: "fpe2", bytes: [0xFF, 0xFC])))
        expect("past the ceiling is refused for floats too", Double?.none,
               SMCDecode.rpm(SMCKeyValue(type: "flt ", bytes: [0x00, 0x00, 0x48, 0x46])))
        expect("and a negative float speed is refused", Double?.none,
               SMCDecode.rpm(SMCKeyValue(type: "flt ", bytes: [0x00, 0x00, 0xE6, 0xC4])))

        print("\nSMCDecode.maxCelsius")
        let hotCPU = SMCKeyValue(type: "flt ", bytes: [0x9A, 0x99, 0xE1, 0x42])   // 112.8
        let warmCPU = SMCKeyValue(type: "flt ", bytes: [0x66, 0x66, 0x7A, 0x42])  // 62.6
        let coolCPU = SMCKeyValue(type: "flt ", bytes: [0x66, 0x66, 0x6A, 0x42])  // 58.6
        expect("the hottest of three, not the mean", "112.80",
               SMCDecode.maxCelsius([warmCPU, hotCPU, coolCPU])
                   .map { String(format: "%.2f", $0) })
        expect("an empty group is nil, not zero", Double?.none, SMCDecode.maxCelsius([]))
        expect("a group where nothing decodes is nil, not zero", Double?.none,
               SMCDecode.maxCelsius([SMCKeyValue(type: "ui16", bytes: [0x00, 0x01])]))

        print("\nSMCDecode.averageCelsius")
        expect("three CPU sensors are averaged, not reduced to the hottest", "78.00",
               SMCDecode.averageCelsius([warmCPU, hotCPU, coolCPU])
                   .map { String(format: "%.2f", $0) })
        expect("an empty average is nil, not zero", Double?.none,
               SMCDecode.averageCelsius([]))
        expect("invalid sensors are omitted from the average", "60.60",
               SMCDecode.averageCelsius([
                   warmCPU,
                   SMCKeyValue(type: "ui16", bytes: [0x00, 0x01]),
                   coolCPU
               ]).map { String(format: "%.2f", $0) })
        expect("an average where nothing decodes is nil, not zero", Double?.none,
               SMCDecode.averageCelsius([
                   SMCKeyValue(type: "ui16", bytes: [0x00, 0x01])
               ]))

        print("\nSMCDecode.cpuAverage")
        let m4CoreKeys = ["Tp0H", "Tp0L", "Tp0P"]
        var m4Readings = m4CoreKeys.map { (key: $0, value: warmCPU) }
        m4Readings.append((key: "Te05", value: hotCPU))
        m4Readings.append((key: "Te0S", value: coolCPU))
        // A real Mac16,5 M4 Max returns 1.5–1.9 from several keys commonly
        // labelled as P cores. They must not enter the aggregate merely because
        // their names begin with Tp.
        m4Readings.append((key: "Tp01", value: SMCKeyValue(
            type: "flt ", bytes: [0x00, 0x00, 0xC0, 0x3F] // 1.5
        )))
        expect("M4 averages only measured domains and weights each E cluster twice", "75.80",
               SMCDecode.cpuAverage(m4Readings, chipName: "Apple M4 Max")
                   .map { String(format: "%.2f", $0) })
        expect("an unknown chip retains the broad-family fallback", "62.60",
               SMCDecode.cpuAverage([(key: "Tp01", value: warmCPU)], chipName: nil)
                   .map { String(format: "%.2f", $0) })
        let intelCPU = SMCKeyValue(type: "sp78", bytes: [0x3E, 0x80])
        let intelHotCore = SMCKeyValue(type: "sp78", bytes: [0x40, 0x00])
        let intelFallback = SMCKeyValue(type: "sp78", bytes: [0x42, 0x00])
        expect("Intel averages its core sensors", 63.25,
               SMCDecode.cpuAverage([
                   (key: "TC1C", value: intelCPU),
                   (key: "TC2C", value: intelHotCore),
                   (key: "TC0P", value: intelFallback)
               ], chipName: "Intel(R) Core(TM) i9") )
        expect("Intel package temperature beats proximity as fallback", 64.0,
               SMCDecode.cpuAverage([
                   (key: "TC0F", value: intelHotCore),
                   (key: "TC0P", value: intelFallback)
               ],
                                    chipName: "Intel(R) Core(TM) i9"))

        // Three whole key tables had no test at all. They are hand-transcribed
        // undocumented four-character codes, and a single typo is a silently
        // wrong CPU temperature on every Mac of that generation — which is
        // exactly the bug 893ddba fixed for M4. One test per table, each
        // proving the table is USED (a wrong table falls through to
        // averageCelsius over everything, which these fixtures make visible).
        let m3Keys = [
            "Te05", "Te0L", "Te0P", "Te0S",
            "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
            "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"
        ]
        var m3Readings = m3Keys.map { (key: $0, value: warmCPU) }   // 62.6 each
        // A key that is not in the M3 table. If the table were wrong or unused,
        // the fallback average would drag the answer towards this.
        m3Readings.append((key: "Tp0H", value: hotCPU))             // 112.8
        expect("M3 averages its sixteen measured keys and ignores keys outside the table",
               "62.60",
               SMCDecode.cpuAverage(m3Readings, chipName: "Apple M3 Pro")
                   .map { String(format: "%.2f", $0) })

        let m2Keys = [
            "Tp1h", "Tp1t", "Tp1p", "Tp1l",
            "Tp01", "Tp05", "Tp09", "Tp0D",
            "Tp0X", "Tp0b", "Tp0f", "Tp0j"
        ]
        var m2Readings = m2Keys.map { (key: $0, value: warmCPU) }
        m2Readings.append((key: "Te05", value: hotCPU))
        expect("M2 averages its twelve measured keys and ignores keys outside the table",
               "62.60",
               SMCDecode.cpuAverage(m2Readings, chipName: "Apple M2")
                   .map { String(format: "%.2f", $0) })

        let m1Keys = [
            "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D",
            "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"
        ]
        var m1Readings = m1Keys.map { (key: $0, value: warmCPU) }
        m1Readings.append((key: "Tf04", value: hotCPU))
        expect("M1 averages its ten measured keys and ignores keys outside the table",
               "62.60",
               SMCDecode.cpuAverage(m1Readings, chipName: "Apple M1")
                   .map { String(format: "%.2f", $0) })
        // Case matters in these codes: Tp0h is not Tp0H. The M2 table is the one
        // that mixes cases, so a case-insensitive lookup would silently merge them.
        expect("an M1 table entry is not matched case-insensitively", "112.80",
               SMCDecode.cpuAverage([(key: "tp09", value: hotCPU)], chipName: "Apple M1")
                   .map { String(format: "%.2f", $0) })

        // The Intel fallback chain in full: TC0F, then TC0E, then TC0P, by
        // precedence and NOT by average — the one arm of this function that
        // takes `.first` rather than a mean.
        expect("Intel falls through TC0F to TC0E before proximity", 64.0,
               SMCDecode.cpuAverage([
                   (key: "TC0E", value: intelHotCore),
                   (key: "TC0P", value: intelFallback)
               ], chipName: "Intel(R) Core(TM) i9"))
        expect("Intel uses proximity only when nothing better decodes", 66.0,
               SMCDecode.cpuAverage([(key: "TC0P", value: intelFallback)],
                                    chipName: "Intel(R) Core(TM) i9"))
        expect("the Intel chain is precedence, not an average of what it found", 64.0,
               SMCDecode.cpuAverage([
                   (key: "TC0F", value: intelHotCore),
                   (key: "TC0E", value: intelFallback),
                   (key: "TC0P", value: intelFallback)
               ], chipName: "Intel(R) Core(TM) i9"))
        // Measured 2026-08-06, and it contradicts what the plan assumed: the
        // Intel arm `return`s the result of its precedence chain, so a nil there
        // is the answer — it never reaches the broad `averageCelsius` fallback
        // the Apple Silicon arm falls through to. That is the right behaviour
        // (a battery sensor must not be reported as a CPU temperature) and it is
        // now pinned, because it is asymmetric enough to be "fixed" by mistake.
        expect("an Intel Mac with no CPU key reports nothing rather than some other sensor",
               Double?.none,
               SMCDecode.cpuAverage([(key: "TB0T", value: warmCPU)],
                                    chipName: "Intel(R) Core(TM) i9"))
        expect("while Apple Silicon does fall through to the broad average", "62.60",
               SMCDecode.cpuAverage([(key: "TB0T", value: warmCPU)],
                                    chipName: "Apple M4 Max")
                   .map { String(format: "%.2f", $0) })

        print("\nSMCDecode.gpuTemperature")
        let intelGPUDie = SMCKeyValue(type: "sp78", bytes: [0x46, 0x00])
        let intelGPUProximity = SMCKeyValue(type: "sp78", bytes: [0x3C, 0x00])
        expect("Intel GPU die beats proximity", 70.0,
               SMCDecode.gpuTemperature([
                   (key: "TG0P", value: intelGPUProximity),
                   (key: "TGDD", value: intelGPUDie)
               ], chipName: "Intel(R) Core(TM) i9"))
        // The Apple Silicon path — the one every M-series Mac takes — had no
        // assertion at all. It is the hottest Tg*, not the mean.
        expect("Apple Silicon takes the hottest GPU sensor, not the average", "112.80",
               SMCDecode.gpuTemperature([
                   (key: "Tg0G", value: warmCPU),
                   (key: "Tg1G", value: hotCPU),
                   (key: "Tg0f", value: coolCPU)
               ], chipName: "Apple M4 Max").map { String(format: "%.2f", $0) })
        expect("and an unknown chip is treated the same way", "112.80",
               SMCDecode.gpuTemperature([
                   (key: "Tg0G", value: warmCPU),
                   (key: "Tg1G", value: hotCPU)
               ], chipName: nil).map { String(format: "%.2f", $0) })
        expect("an Intel Mac where none of the six preferred keys decode falls through", 70.0,
               SMCDecode.gpuTemperature([
                   (key: "TGDD", value: SMCKeyValue(type: "ui16", bytes: [0x00, 0x01])),
                   (key: "Tg0G", value: intelGPUDie)
               ], chipName: "Intel(R) Core(TM) i9"))
        expect("nothing to read is nil, not zero", Double?.none,
               SMCDecode.gpuTemperature([], chipName: "Apple M4 Max"))

        print("\nSMCDecode.group")
        expect("Tp01 is CPU", SMCGroup?.some(.cpuTemp), SMCDecode.group("Tp01"))
        expect("Te05 is an efficiency CPU sensor", SMCGroup?.some(.cpuTemp),
               SMCDecode.group("Te05"))
        expect("Tf04 is an M3 performance CPU sensor", SMCGroup?.some(.cpuTemp),
               SMCDecode.group("Tf04"))
        expect("TC0P is an Intel CPU sensor", SMCGroup?.some(.cpuTemp),
               SMCDecode.group("TC0P"))
        expect("TC1C is an Intel CPU core sensor", SMCGroup?.some(.cpuTemp),
               SMCDecode.group("TC1C"))
        expect("Tg0G is GPU", SMCGroup?.some(.gpuTemp), SMCDecode.group("Tg0G"))
        expect("TG0D is an Intel GPU sensor", SMCGroup?.some(.gpuTemp),
               SMCDecode.group("TG0D"))
        expect("TGDD is an Intel discrete GPU die", SMCGroup?.some(.gpuTemp),
               SMCDecode.group("TGDD"))
        expect("TB0T is battery", SMCGroup?.some(.batteryTemp), SMCDecode.group("TB0T"))
        expect("PSTR is system power", SMCGroup?.some(.systemPower), SMCDecode.group("PSTR"))
        expect("F0Ac is fan 0's actual speed", SMCGroup?.some(.fanSpeed),
               SMCDecode.group("F0Ac"))
        expect("F1Ac is fan 1's actual speed", SMCGroup?.some(.fanSpeed),
               SMCDecode.group("F1Ac"))
        expect("FAAc supports a hexadecimal fan index", SMCGroup?.some(.fanSpeed),
               SMCDecode.group("FAAc"))
        expect("F0Mx is a maximum capability, not the current fan speed", SMCGroup?.none,
               SMCDecode.group("F0Mx"))
        expect("F0Mn is a minimum capability, not the current fan speed", SMCGroup?.none,
               SMCDecode.group("F0Mn"))
        expect("F0Tg is a target, not the current fan speed", SMCGroup?.none,
               SMCDecode.group("F0Tg"))
        expect("FNum is metadata, not a current fan speed", SMCGroup?.none,
               SMCDecode.group("FNum"))
        // PDTR tracks PSTR but spent a whole measurement run pinned at exactly
        // 0.00 (spec §5), so it is deliberately not a source.
        expect("PDTR is not a source", SMCGroup?.none, SMCDecode.group("PDTR"))
        expect("B0AV is not a source", SMCGroup?.none, SMCDecode.group("B0AV"))
        expect("CHTE is not a source — charge power was never observed",
               SMCGroup?.none, SMCDecode.group("CHTE"))

        print("\nSensorFormat")
        expect("nil formats to nil, so the chip is absent rather than empty",
               String?.none, SensorFormat.watts(nil))
        expect("the formatter never emits 0.0 W", String?.none, SensorFormat.watts(0))
        expect("watts carry one decimal", "21.1", SensorFormat.watts(21.15).map {
            String($0.prefix(4))
        })
        expect("temperature rounds to whole degrees", "59 °C", SensorFormat.celsius(58.6))
        expect("nil temperature formats to nil", String?.none, SensorFormat.celsius(nil))
        expect("nil rpm formats to nil", String?.none, SensorFormat.rpm(nil))
        expect("a stopped fan formats as zero rpm", String?.some("0 rpm"),
               SensorFormat.rpm(0))
        expect("rpm rounds to whole", "1840 rpm", SensorFormat.rpm(1840.0))

        print("\nSensorFormat.fan")
        expect("a real speed is a real speed", String?.some("1840 rpm"),
               SensorFormat.fan(1840, sampled: true))
        // A blank column reads as a failed sensor. This Mac has 2130 SMC keys
        // and not one with an F prefix — there is no fan to read, and saying so
        // is the answer rather than the absence of one.
        expect("sampled with nothing to read: No Data", String?.some("No Data"),
               SensorFormat.fan(nil, sampled: true))
        expect("before the first sample, no claim is made", String?.none,
               SensorFormat.fan(nil, sampled: false))
        expect("a stopped fan is shown as stopped, not as missing",
               String?.some("0 rpm"), SensorFormat.fan(0, sampled: true))

        print("\nSensorFormat.temperaturePair")
        // Both halves carry a degree sign — a number with no unit at all is not
        // a reading. The scale is not spelled out twice: two "°C" need 141 pt
        // in a 129.5 pt cell, and the Battery chip beside it names the scale.
        expect("both read: each half carries a degree sign",
               "51°|40°",
               SensorFormat.temperaturePair(cpu: 50.6, gpu: 40.4)
                   .map { "\($0.cpu)|\($0.gpu ?? "")" })
        // Alone in the cell there is room for the scale, and nothing beside it
        // to borrow the scale from.
        expect("CPU alone keeps its unit",
               "51 °C|",
               SensorFormat.temperaturePair(cpu: 50.6, gpu: nil)
                   .map { "\($0.cpu)|\($0.gpu ?? "")" })
        expect("GPU alone stays in the GPU's slot",
               "—|40 °C",
               SensorFormat.temperaturePair(cpu: nil, gpu: 40.4)
                   .map { "\($0.cpu)|\($0.gpu ?? "")" })
        expect("neither reads: no chip at all", String?.none,
               SensorFormat.temperaturePair(cpu: nil, gpu: nil)
                   .map { "\($0.cpu)|\($0.gpu ?? "")" })
        expect("an implausible reading is dropped, not shown bare",
               "51 °C|",
               SensorFormat.temperaturePair(cpu: 50.6, gpu: 500)
                   .map { "\($0.cpu)|\($0.gpu ?? "")" })
        // Both halves round through the same formatter, so the pair cannot
        // disagree with itself about where 50.5 goes.
        expect("both halves round the same way",
               "112°|108°",
               SensorFormat.temperaturePair(cpu: 111.8, gpu: 107.6)
                   .map { "\($0.cpu)|\($0.gpu ?? "")" })

        print("\nSensorFormat.charge")
        expect("charging is labelled and unsigned",
               "Charge 18.3 W",
               SensorFormat.charge(18.28).map { "\($0.label) \($0.value)" })
        // A minus sign under a label reading "Charge" is a puzzle; the label
        // carries the direction instead.
        expect("discharging changes the label, not the sign of the number",
               "Drain 10.3 W",
               SensorFormat.charge(-10.33).map { "\($0.label) \($0.value)" })
        // Unlike every SMC reading in this file, zero here is an answer: a full
        // battery on AC. The caller hides the chip on an unreadable probe.
        expect("zero is a reading, not a decode failure",
               "Charge 0.0 W",
               SensorFormat.charge(0).map { "\($0.label) \($0.value)" })
        expect("nil in, nil out", String?.none,
               SensorFormat.charge(nil).map { "\($0.label) \($0.value)" })
        expect("an implausible rail power is refused", String?.none,
               SensorFormat.charge(9000).map { "\($0.label) \($0.value)" })
        expect("NaN is refused", String?.none,
               SensorFormat.charge(Double.nan).map { "\($0.label) \($0.value)" })
        // The adapter's rating rides along with the battery figure: on its own,
        // "Drain 10.3 W" does not say the machine is losing. Against a 35 W
        // brick it does.
        expect("the adapter rating is appended when there is one",
               "Drain 10.3 W · 35 W PSU",
               SensorFormat.charge(-10.33, adapterWatts: 35)
                   .map { "\($0.label) \($0.value)" })
        expect("unplugged: the battery figure stands alone",
               "Drain 10.3 W",
               SensorFormat.charge(-10.33, adapterWatts: nil)
                   .map { "\($0.label) \($0.value)" })
        expect("a zero rating is no rating",
               "Charge 0.0 W",
               SensorFormat.charge(0, adapterWatts: 0).map { "\($0.label) \($0.value)" })
        expect("an absurd rating is refused, the battery figure is not",
               "Charge 0.0 W",
               SensorFormat.charge(0, adapterWatts: 99_999).map { "\($0.label) \($0.value)" })
        // A desktop has no battery node at all. An empty chip there reads as a
        // failed sensor rather than as a Mac mini.
        expect("no battery: No Data, not an empty chip",
               "Charge No Data",
               SensorFormat.charge(nil, hasBattery: false).map { "\($0.label) \($0.value)" })
        expect("and No Data wins even if a stale figure is passed in",
               "Charge No Data",
               SensorFormat.charge(12.5, adapterWatts: 96, hasBattery: false)
                   .map { "\($0.label) \($0.value)" })

        // Read here rather than reusing the bindings in the drain section
        // below: this block runs before them.
        print("\nSystemProbe.adapterWattsResult")
        expect("the connected adapter's rating", 35,
               SystemProbe.adapterWattsResult(
                   status: 0, output: fixture("ioreg-battery-ac-holding.txt")))
        // AppleRawAdapterDetails carries a Watts of its own, thirty-six lines
        // earlier in the same output. The parser is anchored on AdapterDetails
        // so it cannot answer from that one.
        expect("charging fixture agrees", 35,
               SystemProbe.adapterWattsResult(
                   status: 0, output: fixture("ioreg-battery-charging.txt")))
        expect("no battery node: no rating", Int?.none,
               SystemProbe.adapterWattsResult(
                   status: 0, output: fixture("ioreg-battery-absent.txt")))
        expect("a nonzero exit is refused", Int?.none,
               SystemProbe.adapterWattsResult(
                   status: 1, output: fixture("ioreg-battery-ac-holding.txt")))
        expect("an empty AdapterDetails means nothing is plugged in", Int?.none,
               SystemProbe.adapterWattsResult(
                   status: 0, output: "    \"AdapterDetails\" = {}\n"))

        print("\nSensorFormat.note")
        var abandoned = SensorReadings()
        abandoned.sampled = true
        abandoned.abandoned = true
        abandoned.systemWatts = 12
        expect("abandoned outranks everything, even with a value still showing",
               String?.some("Sensors stopped responding — relaunch Lidless to try again"),
               SensorFormat.note(abandoned, lowPowerActive: true))
        var empty = SensorReadings()
        empty.sampled = true
        expect("a completed sample with nothing in it says so",
               String?.some("No sensors on this Mac"),
               SensorFormat.note(empty, lowPowerActive: false))
        expect("before the first sample, nothing is claimed",
               String?.none,
               SensorFormat.note(SensorReadings(), lowPowerActive: false))
        var live = SensorReadings()
        live.sampled = true
        live.systemWatts = 6.49
        // The Low Power Mode note was removed on request 2026-08-05. Asserted in
        // both directions on purpose: `lowPowerActive` is still in the signature,
        // so a silent re-introduction of the note is exactly what this catches.
        expect("Low Power Mode no longer produces a note",
               String?.none,
               SensorFormat.note(live, lowPowerActive: true))
        expect("nothing to say when readings are live and unthrottled",
               String?.none,
               SensorFormat.note(live, lowPowerActive: false))
        expect("a failing sample still outranks Low Power Mode",
               String?.some("Sensors stopped responding — relaunch Lidless to try again"),
               SensorFormat.note(abandoned, lowPowerActive: true))
        // A failed IOKit open is not evidence that a Mac has no sensors, and the
        // strip used to make that hardware claim after exactly one of them.
        var unreachable = SensorReadings()
        unreachable.sampled = true
        unreachable.connectionFailed = true
        expect("a failed SMC connection says so, and does not claim the Mac has no sensors",
               String?.some("Could not reach the SMC — relaunch Lidless to try again"),
               SensorFormat.note(unreachable, lowPowerActive: false))
        expect("having given up outranks the connection note",
               String?.some("Sensors stopped responding — relaunch Lidless to try again"),
               SensorFormat.note({ var r = unreachable; r.abandoned = true; return r }(),
                                 lowPowerActive: false))
        expect("both failure notes name the remedy, because both states are one-way",
               true,
               (SensorFormat.note(unreachable, lowPowerActive: false) ?? "").contains("relaunch")
                   && (SensorFormat.note(abandoned, lowPowerActive: false) ?? "").contains("relaunch"))

        // SystemProbe.batteryDrainResult — the AC-drain warning. The unsigned
        // amperage is the case that matters: read as written it is a plausible
        // enormous positive current.
        print("\nSystemProbe.batteryDrainResult")
        let acHolding = fixture("ioreg-battery-ac-holding.txt")
        let acDraining = fixture("ioreg-battery-ac-draining.txt")
        let charging = fixture("ioreg-battery-charging.txt")
        let noBattery = fixture("ioreg-battery-absent.txt")

        let drainingResult = SystemProbe.batteryDrainResult(status: 0, output: acDraining)
        expect("unsigned amperage wraps back to −820 mA, not 1.8e19",
               -820, drainingResult.milliamps)
        expect("on AC, not charging, current negative: draining", true, drainingResult.drainingOnAC)
        expect("and it is a real reading", true, drainingResult.readable)

        let holdingResult = SystemProbe.batteryDrainResult(status: 0, output: acHolding)
        expect("a full battery on AC reads 0 mA", 0, holdingResult.milliamps)
        // IsCharging = No is true here too. Without the current, this state and
        // the one above are indistinguishable.
        expect("not charging is not the same as draining", false, holdingResult.drainingOnAC)
        expect("and it is still a real reading", true, holdingResult.readable)

        // −820 mA at 12.608 V. The same arithmetic that was cross-checked
        // against the SMC's own PPBR (10.6 W) in docs/SMC_SENSORS.md §4.
        expect("watts are current times voltage, signed the same way", "-10.34",
               drainingResult.watts.map { String(format: "%.2f", $0) })
        expect("a battery holding at 0 mA is 0 W, not unreadable", "0.00",
               holdingResult.watts.map { String(format: "%.2f", $0) })

        let chargingResult = SystemProbe.batteryDrainResult(status: 0, output: charging)
        expect("charging decodes positive", 1450, chargingResult.milliamps)
        expect("charging watts are positive", "18.28",
               chargingResult.watts.map { String(format: "%.2f", $0) })
        expect("charging is not draining", false, chargingResult.drainingOnAC)

        // `pmset -g batt` lags a plug event by tens of seconds; this flag does
        // not, which is why the tile's source word reads it instead.
        expect("the charger flag is reported alongside the current",
               true, holdingResult.externalConnected)
        expect("and while charging", true, chargingResult.externalConnected)

        let absentResult = SystemProbe.batteryDrainResult(status: 0, output: noBattery)
        expect("no battery node: unreadable, not a confident all-clear",
               false, absentResult.readable)
        expect("and no current", Int?.none, absentResult.milliamps)
        expect("and no power", Double?.none, absentResult.watts)

        let failedResult = SystemProbe.batteryDrainResult(status: 1, output: acDraining)
        expect("a nonzero exit is refused even when the text parses",
               false, failedResult.readable)
        expect("and reports nothing", false, failedResult.drainingOnAC)

        // "Amperage" is a suffix of "InstantAmperage", and the plain-substring
        // form of this parser matched whichever came first in the file — which
        // is "Amperage" = 0, twenty-six lines earlier.
        expect("the key is anchored, so \"Amperage\" cannot answer for \"InstantAmperage\"",
               -820, SystemProbe.batteryDrainResult(status: 0, output: acDraining).milliamps)

        // BatteryPresentation — the Battery tile's line. Pure because the two
        // states it got wrong (charging called "not charging", AC called
        // "battery") could only be caught by hand, in the seconds the machine
        // happened to be in them.
        print("\nBatteryPresentation")
        func detail(
            external: Bool? = true,
            onBattery: Bool = false,
            drainReadable: Bool = true,
            milliamps: Int? = 0,
            drainingOnAC: Bool = false,
            time: BatteryTime = .notCharging
        ) -> String {
            BatteryPresentation.detail(
                sourceReadable: true,
                externalConnected: external,
                onBattery: onBattery,
                drainReadable: drainReadable,
                milliamps: milliamps,
                drainingOnAC: drainingOnAC,
                time: time
            )
        }

        // The reported bug: 1.5 A going in while pmset said "not charging".
        expect("current going in outranks pmset's \"not charging\"",
               "AC · charging", detail(milliamps: 1500, time: .notCharging))
        // The other half of it: pmset still on battery power after the plug.
        expect("and outranks pmset's source, which lags the plug by tens of seconds",
               "AC · charging",
               detail(external: true, onBattery: true, milliamps: 1500, time: .estimating))
        expect("a real estimate is kept — it agrees, and it has a time",
               "AC · 1:23 to full",
               detail(milliamps: 1500, time: .toFull("1:23")))
        expect("held at a charge limit is not charging and says so",
               "AC · not charging", detail(milliamps: 0, time: .notCharging))
        expect("draining on AC replaces the estimate",
               "AC · draining 820 mA",
               detail(milliamps: -820, drainingOnAC: true, time: .notCharging))
        expect("on battery, the estimate is the point",
               "battery · 1:04 left",
               detail(external: false, onBattery: true, milliamps: -820,
                      time: .remaining("1:04")))
        // A desktop, and any Mac whose ioreg pass did not read: fall back to
        // pmset rather than claiming a source nothing confirmed.
        expect("with no ioreg flag, pmset answers for the source",
               "AC · charged",
               detail(external: nil, drainReadable: false, milliamps: nil, time: .charged))
        expect("the shared source label names battery",
               "battery",
               BatteryPresentation.source(
                   sourceReadable: true, externalConnected: false, onBattery: true))
        expect("the shared source label prefers the instant AC flag",
               "AC",
               BatteryPresentation.source(
                   sourceReadable: true, externalConnected: true, onBattery: true))
        expect("the shared source label does not guess after a failed probe",
               "source unreadable",
               BatteryPresentation.source(
                   sourceReadable: false, externalConnected: true, onBattery: false))
        expect("an unreadable source says so instead of guessing",
               "source unreadable",
               BatteryPresentation.detail(
                   sourceReadable: false, externalConnected: true, onBattery: false,
                   drainReadable: true, milliamps: 1500, drainingOnAC: false,
                   time: .notCharging))
        expect("a current that was never read is not a charge",
               false,
               BatteryPresentation.isCharging(drainReadable: false, milliamps: 1500))
        expect("and zero is not a charge either",
               false, BatteryPresentation.isCharging(drainReadable: true, milliamps: 0))

        print("\n\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
