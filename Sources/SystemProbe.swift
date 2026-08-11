// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Dmytro Udovychenko

import Foundation
import Darwin

// MARK: - Shell

enum Shell {
    struct Command: Sendable {
        let executable: String
        let arguments: [String]

        init(_ executable: String, _ arguments: [String] = []) {
            self.executable = executable
            self.arguments = arguments
        }
    }

    /// Which of `collect`'s three failure conditions actually fired.
    ///
    /// `status = -1` collapses them into one number: the child was still running
    /// at the deadline, or it was gone but its output never reached EOF. Those
    /// accuse completely different things — the first is a wedged `ioreg`, the
    /// second is this side of the pipe — and D3a cannot be settled without
    /// telling them apart (`docs/ARCHITECTURE.md`). It is the same
    /// ambiguity `SystemState.probesSkippedForBudget` was added for one layer up:
    /// a distinction that only exists in the caller's head is not evidence.
    ///
    /// Carried in the return value rather than logged from here on purpose:
    /// `SystemProbe.swift` also compiles into the rescue tool, which has no
    /// `PanelLog` — a log call in this file would break that target.
    struct RunDetail: Sendable {
        /// The child was still running when the timeout expired.
        let timedOut: Bool
        /// The child had left the process table by the time the kills were done.
        let exited: Bool
        /// EOF arrived on the pipe, so the output is whole rather than a prefix.
        let drained: Bool

        var summary: String { "timedOut=\(timedOut) exited=\(exited) drained=\(drained)" }

        static let launchFailed = RunDetail(timedOut: false, exited: false, drained: false)
    }

    /// Every probe in this project runs through here, and until 2026-08-02 none of
    /// them had a deadline. One `ioreg` that never returns was enough to wedge the
    /// whole refresh — `refreshInFlight` stays set, no new snapshot ever reaches
    /// the blackout reconcile, and the heartbeat keeps telling the recovery
    /// watchdog the app is healthy. The panel then stays dark through a lid
    /// opening with nothing left to notice. A generous ceiling costs nothing on
    /// probes that take milliseconds and removes that whole class of hang.
    static let defaultTimeout: TimeInterval = 20

    private static func collect(
        _ process: Process,
        timeout: TimeInterval = defaultTimeout
    ) -> (status: Int32, output: String, detail: RunDetail) {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Drained as it arrives, not after the process exits. Reading only once
        // the child has finished deadlocks the pair as soon as the output exceeds
        // the pipe buffer: the child blocks writing, the parent blocks waiting,
        // and a perfectly healthy probe becomes a timeout.
        let collected = Collector()
        let readEnd = pipe.fileHandleForReading
        readEnd.readabilityHandler = { handle in
            let chunk: Data = handle.availableData
            if chunk.isEmpty {
                collected.markFinished()
                handle.readabilityHandler = nil
            } else {
                collected.append(chunk)
            }
        }

        do {
            try process.run()
        } catch {
            readEnd.readabilityHandler = nil
            return (-1, error.localizedDescription, .launchFailed)
        }

        // `ContinuousClock`, not `Date` and not `ProcessInfo.systemUptime`. `Date`
        // moves when the clock is set, so a rollback stretched the deadline
        // towards never. `systemUptime` stops while the machine is asleep — which
        // in THIS app is not a corner case but the entire subject matter: a probe
        // started before a sleep would keep its remaining budget across it and the
        // twenty seconds could span hours of wall time.
        let started = ContinuousClock.now
        let limit = Duration.seconds(timeout)
        func expired(_ budget: Duration) -> Bool { started.duration(to: .now) >= budget }

        while process.isRunning, !expired(limit) {
            Thread.sleep(forTimeInterval: 0.02)
        }
        var timedOut = false
        if process.isRunning {
            timedOut = true
            let pid = process.processIdentifier
            // Snapshotted BEFORE any signal, on purpose: once the direct child
            // dies its children reparent to launchd, and proc_listchildpids(pid)
            // then reports nothing — asking afterwards would always find an empty
            // list and the backstop would be dead code that looks alive.
            let descendants = directChildren(of: pid)
            signalGroup(pid, SIGTERM)
            let afterTerm = limit + .seconds(1)
            while process.isRunning, !expired(afterTerm) { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { signalGroup(pid, SIGKILL) }
            // One bounded sweep, no recursion. The group signal above already
            // covers the ordinary case; this catches a command that put ITSELF
            // in a new group or session (daemonizing tools do), which no group
            // signal aimed at the child's group can reach. Pid reuse inside this
            // few-second window would need the whole pid space to wrap, so the
            // snapshot stays trustworthy for as long as it is used.
            //
            // `child > 0` is not a tidiness check, it is the same hazard
            // `signalGroup` guards and this loop originally did not: `kill(0, sig)`
            // is POSIX-defined as "signal every process in the CALLER's group", so
            // a single stray zero here would SIGKILL Lidless itself. Zero cannot
            // reach `descendants` as the code stands — the buffer is sized from the
            // whole process table, so `proc_listchildpids` can never report more
            // pids than it wrote — but that is an argument about a private call's
            // undocumented return semantics, and the consequence of being wrong is
            // the app killing itself mid-blackout with the panel dark. The check
            // costs one comparison.
            for child: pid_t in descendants where child > 0 && kill(child, 0) == 0 {
                kill(child, SIGKILL)
            }
        }

        // BOUNDED, where this used to be a bare `waitUntilExit()`. SIGKILL is not
        // instant for a process sitting in an uninterruptible system call — and
        // `ioreg` is exactly the kind that can — so the one unbounded wait left on
        // the path was the one placed there to end the others. If it never exits,
        // this returns anyway and Foundation reaps it later.
        let afterKill = limit + .seconds(3)
        while process.isRunning, !expired(afterKill) { Thread.sleep(forTimeInterval: 0.02) }
        let exited = !process.isRunning

        // A bounded drain, and deliberately not `readToEnd()`. That waits for EOF,
        // and EOF only arrives once every holder of the write end lets go — a
        // grandchild of `/bin/bash -c` or of `sudo` keeps it open after its parent
        // has been killed, so the "bounded" path ended in an unbounded read.
        let afterDrain = limit + .seconds(4)
        while !collected.isFinished, !expired(afterDrain) { Thread.sleep(forTimeInterval: 0.01) }
        // Detached, NOT closed. Closing while a callback is between `availableData`
        // and `append` hands it a dead handle; leaving the pipe to ARC costs one
        // descriptor until this returns and cannot race. A late callback can still
        // append after the snapshot below — it is lock-protected, so the worst case
        // is a tail this call does not see, never a crash or a corrupted buffer.
        readEnd.readabilityHandler = nil

        // Nothing partial is ever returned as an answer. `Shell.output` discards
        // the status, so a probe that printed half its output and then hung came
        // back looking exactly like a successful read — and "AppleClamshellState =
        // Yes" from a truncated `ioreg` would have held the panel dark instead of
        // failing safe.
        // `collected.isFinished` too: the direct child exiting is not the same as
        // the output being complete. A grandchild holding the write end means EOF
        // never came, the drain budget simply expired — and returning the real
        // status with whatever had arrived by then was the same "half an answer
        // dressed as a whole one" this guard exists to prevent.
        let detail = RunDetail(timedOut: timedOut, exited: exited, drained: collected.isFinished)
        guard !timedOut, exited, collected.isFinished else { return (-1, "", detail) }

        let text = String(data: collected.data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, text, detail)
    }

    /// Signals the child's whole process GROUP, not just its pid. Killing the
    /// pid alone left grandchildren running: `sudo` (every `runPrivileged*` path
    /// goes through it) is the tracked child, and the actual privileged command
    /// is its grandchild — SIGTERM to `sudo` alone leaves that command alive,
    /// reparented to launchd, holding the pipe's write end open for its full
    /// runtime. `/bin/bash -c` has the same shape.
    ///
    /// No `setpgid()` anywhere: `Process` already spawns every child into a
    /// fresh group of its own, verified empirically against this toolchain
    /// (`getpgid(child) == child` right after `run()`), and `posix_spawn` is
    /// atomic so a post-`run()` `setpgid` could only ever fail with EACCES —
    /// it would be dead code that reads as load-bearing. That default is
    /// undocumented (there is no pgroup API on `Process` at all), which is why
    /// the guard below is a real check and not an assertion.
    ///
    /// The guard is the one hazard `killpg` introduces: `killpg(0, sig)` is
    /// POSIX-defined as "signal the CALLER's own group", so aiming it at a pid
    /// that is not its own group leader could hit Lidless itself. If the
    /// assumption ever stops holding, this degrades to the exact single-pid
    /// behavior that shipped before, not to a new failure mode.
    private static func signalGroup(_ pid: pid_t, _ signal: Int32) {
        if pid > 0, getpgid(pid) == pid {
            killpg(pid, signal)
        } else {
            kill(pid, signal)
        }
    }

    /// Direct children of `pid` from the kernel's real ppid relationships —
    /// unaffected by whatever a command did to its own process group, which is
    /// exactly why it is the backstop for the group signal rather than more of
    /// the same. Empty on any failure; the caller treats that as "nothing to
    /// sweep", never as an error worth failing the probe over.
    private static func directChildren(of pid: pid_t) -> [pid_t] {
        // The nil-buffer call sizes the WHOLE process table, not this pid's
        // children — verified empirically (709 against 690 live processes with
        // three children). That still makes it the right number to ask for: no
        // process can have more children than the system has processes, so one
        // allocation of that size cannot truncate. The return value is a pid
        // COUNT, not a byte count — also verified, since `proc_listpids`, the
        // near-identical call next to it in libproc.h, returns bytes.
        let capacity = Int(proc_listchildpids(pid, nil, 0))
        guard capacity > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: capacity)
        let written = proc_listchildpids(
            pid,
            &buffer,
            Int32(capacity * MemoryLayout<pid_t>.size)
        )
        guard written > 0 else { return [] }
        return Array(buffer.prefix(min(Int(written), capacity)))
    }

    /// Accumulator for `collect`'s readability handler, which runs on its own
    /// queue while the calling thread waits.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        private var finished = false

        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            storage.append(chunk)
        }

        func markFinished() {
            lock.lock(); defer { lock.unlock() }
            finished = true
        }

        var isFinished: Bool {
            lock.lock(); defer { lock.unlock() }
            return finished
        }

        var data: Data {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }

    /// Runs an unprivileged command. Returns exit status and combined output.
    static func run(
        _ command: String,
        timeout: TimeInterval = defaultTimeout
    ) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        let result = collect(process, timeout: timeout)
        return (result.status, result.output)
    }

    /// Runs one executable directly, without involving a shell. Use this for
    /// values read from files or preferences so they can never become shell
    /// syntax, even if a state file was tampered with.
    static func run(
        _ command: Command,
        timeout: TimeInterval = defaultTimeout
    ) -> (status: Int32, output: String) {
        let result = runDetailed(command, timeout: timeout)
        return (result.status, result.output)
    }

    /// `run(Command:)` plus which failure condition fired. Only the lid probe
    /// uses it, and only because D3a needs the distinction; every other caller
    /// stays on the two-value form rather than carrying a field it ignores.
    static func runDetailed(
        _ command: Command,
        timeout: TimeInterval = defaultTimeout
    ) -> (status: Int32, output: String, detail: RunDetail) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        return collect(process, timeout: timeout)
    }

    static func output(
        _ command: String,
        timeout: TimeInterval = defaultTimeout
    ) -> String { run(command, timeout: timeout).output }

    static func output(
        _ command: Command,
        timeout: TimeInterval = defaultTimeout
    ) -> String { run(command, timeout: timeout).output }

    /// Runs a command as root through the system authorization dialog.
    /// macOS collects the password itself — this app never sees it.
    ///
    /// A `true` here only means the command launched and exited 0. Some tools
    /// (`sysadminctl`) exit 0 while writing their refusal to stderr, so callers
    /// must verify the effect rather than trust this alone.
    @MainActor
    static func runPrivileged(_ commands: [Command]) -> (ok: Bool, output: String) {
        guard !commands.isEmpty else { return (true, "") }
        let command = commands.map(shellCommand).joined(separator: " && ")
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"

        var errorInfo: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let number = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
            let message = number == -128
                ? "Cancelled."
                : (errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown error")
            return (false, message)
        }
        return (true, result?.stringValue ?? "")
    }

    /// Uses an installed narrow sudoers rule when every command is allowed,
    /// otherwise falls back to one standard macOS authorization dialog for the
    /// complete batch. Re-running an already-successful pmset assignment in the
    /// fallback is safe and keeps the common installed-helper path prompt-free.
    @MainActor
    static func runPrivilegedPreferNonInteractive(
        _ commands: [Command]
    ) -> (ok: Bool, output: String) {
        guard !commands.isEmpty else { return (true, "") }

        var outputs: [String] = []
        outputs.reserveCapacity(commands.count)
        for command: Command in commands {
            let sudo = Command(
                "/usr/bin/sudo",
                ["-n", command.executable] + command.arguments
            )
            let attempt: (status: Int32, output: String) = run(sudo)
            if attempt.status != 0 {
                return runPrivileged(commands)
            }
            if !attempt.output.isEmpty {
                outputs.append(attempt.output)
            }
        }
        return (true, outputs.joined(separator: "\n"))
    }

    /// Privileged, but silent when a sudoers rule allows it. Falls back to a
    /// dialog for operations such as quit-time cleanup where a person may still
    /// be present to authorize the change.
    @MainActor
    static func runPrivilegedQuietly(_ command: Command) -> (ok: Bool, output: String, prompted: Bool) {
        let sudo = Command(
            "/usr/bin/sudo",
            ["-n", command.executable] + command.arguments
        )
        let attempt = run(sudo)
        if attempt.status == 0 {
            return (true, attempt.output, false)
        }
        let fallback = runPrivileged([command])
        return (fallback.ok, fallback.output, true)
    }

    /// Privileged and strictly non-interactive. Automatic power-off runs when
    /// nobody may be present, so it must never fall back to a password dialog.
    /// The root-owned helper and its narrow sudoers rule are installed once by
    /// tools/install-auto-shutdown.sh.
    static func runPrivilegedNonInteractive(_ command: Command) -> (ok: Bool, output: String) {
        runPrivilegedNonInteractive([command])
    }

    static func runPrivilegedNonInteractive(
        _ commands: [Command]
    ) -> (ok: Bool, output: String) {
        guard !commands.isEmpty else { return (true, "") }

        var outputs: [String] = []
        outputs.reserveCapacity(commands.count)
        for command: Command in commands {
            let sudo = Command(
                "/usr/bin/sudo",
                ["-n", command.executable] + command.arguments
            )
            let attempt: (status: Int32, output: String) = run(sudo)
            if !attempt.output.isEmpty {
                outputs.append(attempt.output)
            }
            guard attempt.status == 0 else {
                return (false, outputs.joined(separator: "\n"))
            }
        }
        return (true, outputs.joined(separator: "\n"))
    }

    static func canRunPrivilegedNonInteractive(
        _ command: Command,
        sudoExecutable: String = "/usr/bin/sudo"
    ) -> Bool {
        let sudo = Command(
            sudoExecutable,
            ["-n", "-l", command.executable] + command.arguments
        )
        let attempt: (status: Int32, output: String) = run(sudo)
        return attempt.status == 0
    }

    private static func shellCommand(_ command: Command) -> String {
        ([command.executable] + command.arguments)
            .map(shellQuote)
            .joined(separator: " ")
    }

    /// Single-quotes a value for `/bin/bash -c`, closing and reopening the quote
    /// around any quote inside it. `internal`, not `private`, because
    /// `Sources/main.swift` had a byte-identical private copy — two
    /// implementations of one escaping rule, which is one more than a quoting
    /// rule should ever have.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func notify(_ title: String, _ body: String) {
        let source = "display notification \(appleScriptString(body)) with title \(appleScriptString(title))"
        _ = run(Command("/usr/bin/osascript", ["-e", source]))
    }

    private static func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }
}

// MARK: - System state

struct SystemState: Sendable {
    var caffeinatePID: Int?
    var privilegedSupportInstalled = false
    var lidIgnored = false
    var screenLockDelay = "unknown"
    var onBattery = false
    var batteryPercent: Int?
    var batteryTime: BatteryTime = .unknown
    var lidClosed = false
    var hasLid = true
    var hasBattery = true
    /// Whether `hasBattery` reflects a confirmed presence/absence rather than
    /// an ambiguous read defaulting to "attempt anyway" (see `hasBattery`'s
    /// own assignment in `read(pidFile:)`).
    var hasBatteryReadable = false
    var lowPowerAC = false
    var lowPowerBattery = false
    var lidStateReadable = false
    /// Whether `read(pidFile:)` ran out of `readOverallBudget` and skipped one or
    /// more probes. A skipped probe is deliberately indistinguishable from a
    /// failed one to every parser downstream — that is what keeps them on their
    /// existing unreadable paths — but it must not be indistinguishable to an
    /// INVESTIGATOR. On 2026-08-03 a spurious `hasLid=false` restored the panel
    /// under a closed lid, and "the clamshell key was absent" and "the clamshell
    /// probe never ran" were two very different explanations that the record
    /// could not tell apart.
    var probesSkippedForBudget = false
    /// How long the whole `read(pidFile:)` took. D3a: a bad reading and a slow
    /// one look identical in the record otherwise, and the interval between a
    /// stalled probe and the teardown it caused (~24 s, measured three times)
    /// only made sense once `Shell.defaultTimeout` was put next to it.
    var readDuration: Duration = .zero
    var powerSettingsReadable = false
    /// Whether `onBattery` reflects a real reading rather than a failed
    /// probe's default. A failed `pmset -g batt` used to read identically to
    /// a genuinely-on-AC Mac, silently disabling battery-percent auto-off.
    var powerSourceReadable = false
    /// Whether `lowPowerAC`/`lowPowerBattery` reflect confirmed readings
    /// rather than lowPower(in:section:)'s lenient `false` default — gates
    /// performEnable's Low Power Mode save, which must not write a
    /// fabricated "original value" it cannot actually confirm.
    var lowPowerACReadable = false
    var lowPowerBatteryReadable = false

    /// Battery current in milliamps: negative while discharging, positive while
    /// charging. From `ioreg`'s `InstantAmperage`, not from the SMC — see
    /// `batteryDrainResult`.
    var batteryAmperageMilliamps: Int?
    /// Battery rail power in watts, signed the same way as the current above:
    /// positive is charge going in. Not from the SMC either — the SMC's own
    /// battery-rail keys report a magnitude with no direction, and direction is
    /// the whole point of this one.
    var batteryPowerWatts: Double?
    /// The connected power adapter's rating in watts, or nil when there is no
    /// adapter or nothing readable. A rating, not a measurement — see
    /// `adapterWattsResult`.
    var adapterWatts: Int?
    /// Whether a charger is physically connected, from `ioreg`'s
    /// `ExternalConnected`.
    ///
    /// This exists because `pmset -g batt`'s `Now drawing from …` lags a plug
    /// event by tens of seconds: observed 2026-08-05 with the tile reading
    /// `battery · estimating…` while the battery was taking 26 W in. Anything
    /// that only *describes* the power source should prefer this; `onBattery`
    /// stays the pmset-derived value the policy code has always used, because
    /// changing what drives auto-shutdown is a different decision.
    var batteryExternalConnected: Bool?
    /// On AC and still losing charge, because the load exceeds what the adapter
    /// supplies. Measured on 2026-08-05: a 21 W SoC load on a 35 W adapter drew
    /// −820 mA out of the battery with `IsCharging = No` (docs/SMC_SENSORS.md
    /// §4). For a laptop left plugged in for days as a remote-desktop host,
    /// that is the difference between "fine" and "will die tonight".
    var batteryDrainingOnAC = false
    /// Whether the two fields above were actually read. The flag form, not a
    /// bare Optional, for the reason given at the top of this struct: `false`
    /// ("not draining") is a plausible-looking default that a failed probe
    /// would otherwise be indistinguishable from, and this one is a warning —
    /// silence must mean "checked and fine", never "never looked".
    var batteryDrainReadable = false

    var keepAwakeActive: Bool { caffeinatePID != nil }
    var isFullyOn: Bool { keepAwakeActive && lidIgnored }
    var isFullyOff: Bool { !keepAwakeActive && !lidIgnored }

    /// Whether Low Power Mode is on for at least one power source.
    ///
    /// Deliberately not "as it applies right now, for the source in use", which is
    /// what this used to be: the row that colours itself by this already names the
    /// sources the mode is on for, so keying the colour to the source in use made
    /// the very same word render green or grey depending on whether the charger
    /// happened to be plugged in — decodable only by reading the Power row below it.
    var lowPowerActiveAnywhere: Bool { lowPowerAC || (hasBattery && lowPowerBattery) }

    /// Whether Low Power Mode will stay enabled after switching power sources.
    /// Desktops have no battery setting, so AC alone is sufficient there.
    var lowPowerActiveEverywhere: Bool {
        lowPowerAC && (!hasBattery || lowPowerBattery)
    }

    /// The lid is ignored but nothing is managing it. This setting is written to
    /// /Library/Preferences/com.apple.PowerManagement.plist and survives reboots,
    /// so a Mac left like this never sleeps again until someone resets it.
    var isOrphaned: Bool { lidIgnored && !keepAwakeActive }

    /// Ignored/normal collapse `lidStateReadable` away, which is how
    /// isFullyOn/isFullyOff ended up able to show a confident "OFF" for a lid
    /// probe that was never actually confirmed (`lidIgnored` defaults false
    /// when unreadable). UI code should branch on this pure, testable
    /// three-way value instead of re-deriving it ad hoc in each view. See
    /// docs/ARCHITECTURE.md.
    var lidPresentation: LidPresentation {
        guard lidStateReadable else { return .unknown }
        return lidIgnored ? .ignored : .normal
    }
}

enum LidPresentation: Equatable, Sendable {
    case ignored
    case normal
    case unknown
}

enum LowPowerEnableDecision: Equatable, Sendable {
    case attempt
    case skip(message: String?)
}

/// How Panel blackout darkens the built-in panel. Two genuinely different trades,
/// which is why this is a choice rather than a fallback picked automatically.
///
/// `.virtualDisplay` switches the panel off. Measured 2026-08-02: disabling the
/// display drives its backlight to zero and holds it there. The cost is that the
/// session has to live somewhere, so it moves to a virtual display — 1x instead
/// of 2x, window positions and Spaces not guaranteed, remote desktop renegotiated.
///
/// `.dim` leaves the display enabled and only takes the brightness down. Nothing
/// about the session changes, so none of those artefacts can occur — and it
/// **cannot blind the Mac**, because the panel never leaves the display
/// configuration. That is the whole failure mode the watchdog, the rescue tool
/// and the four-layer recovery model exist for, and it is structurally absent
/// here. The price is that the panel is not off: the hardware minimum is about
/// 0.5 % of full (§2.10 item 1), so it is very dim rather than dark.
enum PanelMode: String, CaseIterable, Equatable, Sendable {
    case virtualDisplay = "virtual"
    case dim = "dim"

    /// Virtual display, because it is the mode that actually solves the stated
    /// problem — a lit panel behind a closed lid. `.dim` is the escape hatch for
    /// when its side effects are worse than the symptom.
    static let `default`: PanelMode = .virtualDisplay

    /// Short on purpose: these are the two segments of a picker that shares its
    /// row with the option it belongs to, and anything longer truncates to an
    /// ellipsis at the width that row reserves for it (`rowAccessoryWidth` in
    /// `ContentView`). The full explanation of each lives in the picker's `help`,
    /// not here.
    ///
    /// Named after what happens to the PANEL, not after the mechanism. "Virtual
    /// display" is the one exception and earns it: that mode's side effects are
    /// all consequences of the session moving, so naming the cause is what makes
    /// the warning about window positions read as related rather than arbitrary.
    var title: String {
        switch self {
        case .virtualDisplay: return "Virtual display"
        case .dim: return "Keep panel on"
        }
    }
}

/// What the built-in panel is doing, as one three-way value rather than a pair of
/// booleans each view re-derives. `.unknown` is a real answer here: the display
/// probe needs CoreGraphics, which this file deliberately cannot import, so a build
/// or a caller without it reports honestly instead of guessing `.lit`.
enum PanelPresentation: Equatable, Sendable {
    /// Enabled and bright enough to read.
    case lit
    /// Switched off by Panel blackout, with the session on a virtual display.
    case dark
    /// Dark or disabled with nobody managing it — the display equivalent of
    /// `SystemState.isOrphaned`, and the one case a human needs told about.
    case stranded
    case unknown

    /// The row text, kept here for the same reason as `BatteryTime.summary`: the
    /// window and the menu bar panel are separate structs that cannot share a
    /// private helper, and this must not end up worded two ways.
    var summary: String {
        switch self {
        case .lit: return "on"
        case .dark: return "dark"
        case .stranded: return "stranded — press Restore"
        case .unknown: return "unknown"
        }
    }
}

/// Whether Panel blackout may disable the built-in display right now.
enum BlackoutDecision: Equatable, Sendable {
    case proceed(builtinID: UInt32)
    case refuse(reason: String)
}

/// What to do about the built-in panel's brightness while putting things back.
enum PanelBrightnessDecision: Equatable, Sendable {
    /// The screen is already legible. Writing to it would overwrite a good value
    /// with a guess — measured 2026-08-01, macOS restores the user's own
    /// brightness within seconds of an app-scoped display config reverting, and a
    /// rescue that fired anyway replaced 0.0625 with a floor of its own.
    case leaveAlone
    case restore(Float)
}

/// Whether the display standing in for the panel is still there.
///
/// Both signals, because either can be the first to know: the display's own
/// termination callback, and the window server's active list. Checking only
/// the callback — which is what the post-mutation guard and `sessionDisplayLost`
/// did — accepted a blackout whose carrier had already left the list while the
/// callback was still in flight, or never arrived at all.
///
/// Three answers, not two, and the third is the whole point. Collapsing an
/// unreadable display list into "gone" made one transient `CGGetActiveDisplayList`
/// failure tear a working blackout down — and the goal then flipped straight
/// back to `.dark`, building a fresh virtual display, resetting the attempt
/// budget as it went. Neither the backoff nor the cap bounds that, because
/// both reset on success and on a change of goal. Five virtual displays in ten
/// seconds is the documented way this Mac ended up with no displays at all
/// (docs/ARCHITECTURE.md), so an unbounded churn loop is not a lesser failure than the
/// one the check was added to catch.
enum CarrierState: Equatable, Sendable {
    case alive
    case gone
    case unknown
    /// Switched off along with every other display because the display domain
    /// slept — **not** lost. Measured 2026-08-04 with a carrier created outside
    /// the app: during `pmset displaysleepnow` the active list emptied
    /// completely (the built-in went too), and on wake the carrier came back
    /// with its termination callback never having fired.
    ///
    /// Its own case rather than folding into `.alive`, because the two lead
    /// somewhere different: `.alive` is a precondition for switching the panel
    /// off, and arming a blackout while the display domain is asleep would be
    /// darkening a panel that is already dark.
    case asleep
}

/// Which way Panel blackout is currently trying to go. Kept so the retry
/// budget resets the moment the goal flips, rather than carrying a failed
/// blackout's exhausted attempts into the restore that follows it.
enum PanelGoal: Equatable, Sendable {
    case dark
    case lit
}

/// Whether reconcile should wait, give up and hand over, or attempt now —
/// and the backoff to apply when it does.
enum PanelAttemptVerdict: Equatable, Sendable {
    case wait
    /// `showMessage` fires for the cap being reached at all, regardless of
    /// `goal`/`hasPanelToRestore`. `shouldEscalate` is a strict subset —
    /// escalation additionally requires the goal to be `.lit` with something
    /// to restore — so both are carried separately rather than one derived
    /// from the other: gating the message on `shouldEscalate` alone would
    /// silently drop it for a `.dark`-goal cap-out or a `.lit` goal with
    /// nothing to restore.
    case capReached(showMessage: Bool, shouldEscalate: Bool)
    case proceed(nextAttempt: ContinuousClock.Instant)
}

enum ChurnOutcome: Equatable, Sendable {
    case proceed
    case rateLimited
    case ceilingReached
}

/// `prunedHistory` is unconditional — needed on every outcome, not just
/// `.proceed` — because the caller must persist it regardless of whether a
/// new virtual display is actually about to be built. Carrying it inside an
/// enum payload on only one case would force the caller to re-run the same
/// window filter itself outside this "pure" function, a second place for the
/// prune rule to drift from the first.
struct ChurnResult: Equatable, Sendable {
    let prunedHistory: [Date]
    let outcome: ChurnOutcome
}

/// Stable identity deliberately assigned to every virtual display created by
/// Lidless. Keeping it outside the private CoreGraphics wrapper makes the exact
/// matching rule testable without loading any display framework.
enum LidlessVirtualDisplayIdentity {
    static let vendorID: UInt32 = 0x4C49
    static let productID: UInt32 = 0x4444
    static let serialNumber: UInt32 = 0x4C49_4444
}

/// Whether restoring an Intel panel backed by a virtual carrier may start now.
/// A closed Intel clamshell can make the CoreGraphics enable call stop returning,
/// but quitting cannot simply skip that call: destroying the carrier first leaves
/// WindowServer and ControlStrip pointing at a display that no longer exists.
enum PanelRestoreSchedule: Equatable, Sendable {
    case now
    case waitForLidOpen
}

/// Dimensions handed to CGVirtualDisplayMode. The private API interprets its
/// width and height differently on the two Mac architectures we support:
/// Apple Silicon applies the requested HiDPI mode to physical pixels, while
/// Intel leaves the same numbers as 1x points.
struct VirtualDisplayModeDimensions: Equatable, Sendable {
    let width: Int
    let height: Int
}

enum BatteryPresence: Equatable, Sendable {
    case yes
    case no
    case unknown
}

enum CaffeinatePIDQueryResult: Equatable, Sendable {
    case found([Int])
    case none
    case failed
}

/// What `pmset -g batt` says about how long the battery has left, or how long it
/// needs. Separate cases rather than an optional string, because "macOS has not
/// worked out an estimate yet" and "there is nothing to estimate, the charger is
/// in and the battery is full" are different answers that a nil would flatten.
enum BatteryTime: Equatable, Sendable {
    /// Discharging, with an estimate. `"1:04"`.
    case remaining(String)
    /// Charging, with an estimate of when it will be full. `"1:23"`.
    case toFull(String)
    case charged
    /// On AC and deliberately not charging — a charge limit, or optimised
    /// charging holding it back. There is no time to show and nothing is wrong.
    case notCharging
    /// macOS prints `(no estimate)` for a while after the source changes.
    case estimating
    case unknown

    /// The row text, kept here rather than in each view: the window and the menu
    /// bar panel are separate structs that cannot share a private helper, and this
    /// is one estimate that must not be worded two ways. `LowPowerEnableDecision`
    /// already carries its own user-facing message for the same reason.
    var summary: String {
        switch self {
        case .remaining(let time): return "\(time) left"
        case .toFull(let time): return "\(time) to full"
        case .charged: return "charged"
        case .notCharging: return "not charging"
        case .estimating: return "estimating…"
        case .unknown: return "unknown"
        }
    }
}

/// What the Battery tile says about the source and the charge.
///
/// Pure and tested, unlike the tile's other computed properties, because this
/// particular decision was wrong twice on 2026-08-05 and both times the only
/// way to see it was to catch the machine in the right state by hand. The rule
/// it encodes: **`pmset` describes the charge, the current *is* the charge.**
/// `pmset -g batt` lags a plug event by tens of seconds and has been observed
/// calling a 1.5 A charge `not charging`.
enum BatteryPresentation {
    /// Charge actually going into the battery. From the current, never from a
    /// flag — `IsCharging` was `No` while 1.5 A went in.
    static func isCharging(drainReadable: Bool, milliamps: Int?) -> Bool {
        drainReadable && (milliamps ?? 0) > 0
    }

    /// Whether a charger is connected, preferring `ioreg`'s instant flag over
    /// `pmset`'s lagging one. Falls back to `pmset` when the `ioreg` pass did
    /// not read, which is the desktop and the failed-probe case.
    static func onExternalPower(externalConnected: Bool?, onBattery: Bool) -> Bool {
        externalConnected ?? !onBattery
    }

    /// The current power source, shared by every tile that names it. Keep the
    /// readability gate even when `externalConnected` has a default-looking
    /// value: an unread probe must not turn into a confident AC/battery claim.
    static func source(
        sourceReadable: Bool,
        externalConnected: Bool?,
        onBattery: Bool
    ) -> String {
        guard sourceReadable else { return "source unreadable" }
        return onExternalPower(
            externalConnected: externalConnected,
            onBattery: onBattery
        ) ? "AC" : "battery"
    }

    /// The line under the percentage: source, then what is happening.
    static func detail(
        sourceReadable: Bool,
        externalConnected: Bool?,
        onBattery: Bool,
        drainReadable: Bool,
        milliamps: Int?,
        drainingOnAC: Bool,
        time: BatteryTime
    ) -> String {
        let source: String = source(
            sourceReadable: sourceReadable,
            externalConnected: externalConnected,
            onBattery: onBattery
        )
        guard source != "source unreadable" else { return source }

        // Plugged in and still losing charge — the load is more than the
        // adapter supplies (docs/SMC_SENSORS.md §4). It replaces the estimate
        // rather than joining it, because on AC that estimate is "not
        // charging", which is the very thing that makes the state look normal.
        if drainingOnAC, let milliamps: Int = milliamps {
            return "\(source) · draining \(abs(milliamps)) mA"
        }

        // `toFull` is the one estimate that survives a positive current: it
        // agrees with it, and it carries a time the current does not have.
        if isCharging(drainReadable: drainReadable, milliamps: milliamps) {
            switch time {
            case .toFull: break
            default: return "\(source) · charging"
            }
        }
        return "\(source) · \(time.summary)"
    }
}

// MARK: - Probe

/// All the shell work, kept off the main actor. One pass reads everything.
///
/// The parsing is split out from the command execution so tests/run.sh can drive
/// it against the same fixture files the shell parsers use. Keep the two in
/// step: `lowPower(in:section:)` here and `parse_pmset_custom` in lidless.sh
/// must agree, or the app and the script will disagree about the same Mac.
enum SystemProbe {
    /// Keep the shell copy in lidless.sh and the installer in sync. Swift code
    /// uses this one constant so permission probing and invocation cannot drift.
    static let automaticShutdownHelperPath =
        "/Library/PrivilegedHelperTools/io.github.lidless.poweroff"
    private static let automaticShutdownHelperVersionMarker =
        "LIDLESS_POWEROFF_VERSION=\"2\""

    /// Every privileged command covered by the one-time Lidless permission.
    /// Keep this list in sync with tools/install-auto-shutdown.sh. Checking the
    /// complete set prevents a partial or old sudoers file from being presented
    /// as ready: Enable and Disable must both be silent, not just shutdown.
    private static func requiredPrivilegedCommands(helperPath: String) -> [Shell.Command] {
        [
            Shell.Command(helperPath),
            Shell.Command("/usr/bin/pmset", ["-a", "disablesleep", "1"]),
            Shell.Command("/usr/bin/pmset", ["-a", "disablesleep", "0"]),
            Shell.Command("/usr/bin/pmset", ["-a", "lowpowermode", "1"]),
            Shell.Command("/usr/bin/pmset", ["-c", "lowpowermode", "0"]),
            Shell.Command("/usr/bin/pmset", ["-c", "lowpowermode", "1"]),
            Shell.Command("/usr/bin/pmset", ["-b", "lowpowermode", "0"]),
            Shell.Command("/usr/bin/pmset", ["-b", "lowpowermode", "1"]),
        ]
    }

    /// One ceiling for a whole `read`, on top of `Shell.defaultTimeout`'s
    /// per-probe one. A snapshot runs up to fourteen sequential `Shell` calls
    /// (eight of them inside `privilegedSupportInstalled`), each independently
    /// allowed twenty seconds and nothing capping the sum — a machine where
    /// several probes crawl could hold a refresh for minutes, which is
    /// indistinguishable from the wedged-refresh failure `Shell.defaultTimeout`
    /// was added to end.
    ///
    /// Chosen, not measured — this project's convention for values of this kind
    /// (docs/ARCHITECTURE.md). Generous enough that three or four slow probes on a
    /// merely loaded machine never trip it, tight enough that the true worst
    /// case becomes about a minute and a half instead of ~280s.
    ///
    /// The bound is 75s + one `Shell.defaultTimeout`, not 75s flat: the budget
    /// is checked BETWEEN probes, so a probe already in flight when it runs out
    /// still gets its own full twenty seconds. Interrupting one mid-call would
    /// mean a second deadline inside `collect` for no real gain — the point is
    /// to stop the *sum* from growing without limit, and it does.
    static let readOverallBudget: Duration = .seconds(75)

    /// Reads everything the UI and the blackout reconcile need in one snapshot.
    ///
    /// Bounded by `readOverallBudget` as a whole: once it is spent, remaining
    /// probes are skipped and the partial `SystemState` is returned as-is. That
    /// is not a new failure mode — every field already carries a safe
    /// "unreadable" default for the probe that never ran, the same shape an
    /// individually failed probe produces today.
    ///
    /// `ContinuousClock`, never `Date` and never `systemUptime`, for the reasons
    /// spelled out at `Shell.collect`.
    ///
    /// `budget` is a parameter only so the exhausted path is reachable from a
    /// test in milliseconds instead of 75 seconds. Production never passes it.
    static func read(
        pidFile: String,
        privilegedSupportOverride: Bool? = nil,
        budget: Duration = readOverallBudget
    ) -> SystemState {
        let deadline = ContinuousClock.now + budget
        let readBegan = ContinuousClock.now
        var state = SystemState()
        // Records the miss as well as reporting it. Every caller of this keeps
        // its existing unreadable-value path, which is the point — but the fact
        // that a value is unreadable *because nothing asked* is now recoverable
        // from the state itself. Covers the sequential probes below;
        // `privilegedSupportInstalled(deadline:)` has its own deadline check and
        // is not counted here.
        func budgetLeft() -> Bool {
            guard .now < deadline else {
                state.probesSkippedForBudget = true
                return false
            }
            return true
        }

        state.privilegedSupportInstalled = privilegedSupportOverride
            ?? privilegedSupportInstalled(deadline: deadline)

        if budgetLeft(),
           let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
           let pid = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           isCaffeinateProcess(pid) {
            state.caffeinatePID = pid
        }

        if budgetLeft(), let lidIgnored = lidIgnored() {
            state.lidIgnored = lidIgnored
            state.lidStateReadable = true
        }

        // `pmset -g custom` is the slowest call here, so read it once and parse
        // both sections from the same text.
        //
        // A skipped probe's `(-1, "")` is deliberately the same value a failed
        // one produces, so every parser below stays on its existing
        // unreadable path instead of needing a second notion of "absent".
        let customResult = budgetLeft()
            ? Shell.run(Shell.Command("/usr/bin/pmset", ["-g", "custom"]))
            : (status: Int32(-1), output: "")
        let custom = customResult.output
        state.powerSettingsReadable = customResult.status == 0 && custom.contains("AC Power")

        let batteryResult = budgetLeft()
            ? Shell.run(Shell.Command("/usr/bin/pmset", ["-g", "batt"]))
            : (status: Int32(-1), output: "")
        let batteryInfo = batteryResult.output
        (state.powerSourceReadable, state.onBattery) = powerSourceResult(
            status: batteryResult.status,
            output: batteryInfo
        )

        // A tri-state presence result — not a bare string-contains fold, which
        // ignored both commands' exit statuses (a failed-outright probe used
        // to read identically to a confirmed desktop). `hasBattery` is true
        // unless presence is CONFIRMED absent, matching the fail-safe
        // philosophy already used for the lid setting elsewhere: attempting
        // the battery-side Low Power Mode restore on a machine that turns out
        // to have no battery is a harmless no-op, while skipping it on a
        // machine that does would silently strand the setting. See
        // docs/ARCHITECTURE.md — review round 3.
        let presence = batteryPresenceResult(
            customStatus: customResult.status, custom: custom,
            batteryStatus: batteryResult.status, batteryInfo: batteryInfo
        )
        state.hasBattery = presence != .no
        state.hasBatteryReadable = presence != .unknown
        let acValue = lowPowerValue(in: custom, section: "AC Power")
        state.lowPowerAC = acValue ?? false
        state.lowPowerACReadable = acValue != nil
        if state.hasBattery {
            let batteryValue = lowPowerValue(in: custom, section: "Battery Power")
            state.lowPowerBattery = batteryValue ?? false
            state.lowPowerBatteryReadable = batteryValue != nil
        } else {
            state.lowPowerBattery = false
            state.lowPowerBatteryReadable = true // nothing to read on a confirmed desktop
        }
        if state.hasBattery {
            state.batteryPercent = batteryPercent(in: batteryInfo)
            state.batteryTime = batteryResult.status == 0 ? batteryTime(in: batteryInfo) : .unknown

            // The one `ioreg` read for the AC-drain warning. Deliberately NOT
            // piped to grep: an early-exiting consumer kills `ioreg` with
            // SIGPIPE, the trap already documented for the clamshell read
            // below. Deliberately a subprocess behind `Shell.defaultTimeout`
            // too, unlike the SMC strip's sensors — this is the timeout-bounded
            // path, and that is why the drain warning lives here while the
            // watts and temperatures do not (docs/SMC_SENSORS.md §4a).
            let drainResult = budgetLeft()
                ? Shell.run(Shell.Command("/usr/sbin/ioreg", ["-rn", "AppleSmartBattery"]))
                : (status: Int32(-1), output: "")
            let drain = batteryDrainResult(status: drainResult.status, output: drainResult.output)
            state.batteryDrainReadable = drain.readable
            state.batteryAmperageMilliamps = drain.milliamps
            state.batteryPowerWatts = drain.watts
            state.batteryDrainingOnAC = drain.drainingOnAC
            state.batteryExternalConnected = drain.externalConnected
            state.adapterWatts = adapterWattsResult(
                status: drainResult.status,
                output: drainResult.output
            )
        }

        // Desktops have no clamshell key at all — do not report a lid they lack.
        //
        // Deliberately not `ioreg ... | grep -m1`: the app runs this through
        // /bin/bash, and an early-exiting consumer kills ioreg with SIGPIPE. The
        // shell script hit exactly that bug; read it all and match in memory.
        let clamshell = budgetLeft()
            ? Shell.output(Shell.Command(
                "/usr/sbin/ioreg",
                ["-r", "-k", "AppleClamshellState"]
            ))
            : ""
        state.hasLid = clamshell.contains("AppleClamshellState")
        state.lidClosed = clamshellClosed(in: clamshell)

        // Left at its "unknown" default when the budget is gone — the same
        // string screenLock() itself returns for an unreadable answer.
        if budgetLeft() {
            state.screenLockDelay = screenLock()
        }
        state.readDuration = readBegan.duration(to: .now)
        return state
    }

    /// `deadline` is `read`'s shared budget: this loop is the single biggest
    /// contributor to a snapshot's worst case (eight of its up-to-fourteen
    /// `Shell` calls), so it has to honour the budget from inside, not only at
    /// its edges. Running out reads as "not installed" — the same conservative
    /// answer an outright failed check gives, and the one that keeps the app
    /// from claiming a privileged path it has not confirmed. Optional with a
    /// default so the existing unit-test call sites need no deadline.
    static func privilegedSupportInstalled(
        helperPath: String = automaticShutdownHelperPath,
        sudoPath: String = "/usr/bin/sudo",
        requiredVersionMarker: String? = automaticShutdownHelperVersionMarker,
        deadline: ContinuousClock.Instant? = nil
    ) -> Bool {
        let fileManager: FileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: helperPath) else { return false }
        if let requiredVersionMarker {
            guard let helperText: String = try? String(
                contentsOfFile: helperPath,
                encoding: .utf8
            ), helperText.split(separator: "\n").contains(Substring(requiredVersionMarker)) else {
                return false
            }
        }
        for command: Shell.Command in requiredPrivilegedCommands(helperPath: helperPath) {
            if let deadline, ContinuousClock.now >= deadline { return false }
            guard Shell.canRunPrivilegedNonInteractive(
                command,
                sudoExecutable: sudoPath
            ) else {
                return false
            }
        }
        return true
    }

    /// Whether Enable must refuse: a shutdown limit is selected while the
    /// one-time privileged support for it is not installed. Enabling anyway
    /// arms a limit that can never fire, so the app would sit there claiming a
    /// power-off it cannot perform.
    ///
    /// One function because there were two answers. `ContentView` disabled its
    /// Enable button on exactly this condition; `MenuBarPanel`'s Enable — same
    /// controller, same effect — had no check at all, not a laxer one, so the
    /// popover could start a session the main window refused. The controller now
    /// enforces it and both surfaces read the same computation, which is also
    /// what makes the rule testable without a UI.
    static func privilegeSetupBlocksEnable(
        shutdownAfterHours: Int,
        shutdownBelowBatteryPercent: Int,
        privilegedSupportInstalled: Bool
    ) -> Bool {
        let automaticShutdownSelected: Bool =
            shutdownAfterHours > 0 || shutdownBelowBatteryPercent > 0
        return automaticShutdownSelected && !privilegedSupportInstalled
    }

    /// Interprocess lock so a concurrent CLI + app enable/disable cannot race
    /// on stale state and start two caffeinate processes. Calls the real
    /// flock(2) kernel lock directly — lidless.sh's with_lock() locks the
    /// same file via the /usr/bin/lockf command-line tool, which its own man
    /// page confirms wraps flock(2); verified empirically (during
    /// implementation) that a lock held one way is correctly seen by the
    /// other. Non-blocking: returns nil immediately if already held, rather
    /// than waiting — these are short interactive operations, not queued
    /// jobs. Returns the locked file descriptor on success; the caller owns
    /// releasing it via releaseLock(_:), typically in a `defer`. See
    /// docs/ARCHITECTURE.md.
    static func acquireLock(path: String) -> Int32? {
        // `O_CLOEXEC`, for the same reason `lidless.sh`'s `with_lock` now closes
        // fd 9 in its children: a lock descriptor inherited by a long-lived child
        // keeps the lock held for that child's lifetime, because `flock` releases
        // only when every descriptor referring to the file is closed. The shell
        // side of this was measured on 2026-08-04 — `caffeinate` inherited fd 9
        // and held the interprocess lock for the whole session, silently
        // starving the app's automatic blackout.
        //
        // Nothing in this process is known to spawn a child while holding it,
        // which is exactly why this is worth setting now rather than after the
        // one that does gets added.
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Releases a lock from acquireLock(path:). Closing the descriptor drops
    /// the flock(2) lock immediately — including if the process were to
    /// crash first, the kernel does this on its own, so there is no stale-lock
    /// cleanup to get wrong on either side.
    static func releaseLock(_ fd: Int32) {
        close(fd)
    }

    /// Whether performEnable should attempt applying Low Power Mode, and what
    /// message (if any) to show when it should not — pure, so it is directly
    /// testable without the untested `Lidless` controller. Extracted per
    /// docs/ARCHITECTURE.md "Testable seam" (this was
    /// promised in the plan but not actually done on the first implementation
    /// pass — caught in review round 1).
    static func lowPowerEnableDecision(
        wantsLowPower: Bool,
        lowPowerActiveEverywhere: Bool,
        powerSettingsReadable: Bool,
        currentValuesReadable: Bool,
        hasSavedLowPowerFile: Bool,
        savedLowPowerValid: Bool
    ) -> LowPowerEnableDecision {
        guard wantsLowPower, !lowPowerActiveEverywhere else {
            return .skip(message: nil)
        }
        guard powerSettingsReadable else {
            return .skip(message: "Could not read the current Low Power Mode; it was left unchanged.")
        }
        // Only matters when about to save a fresh restore point — an
        // existing saved file means there's nothing new to read here.
        guard hasSavedLowPowerFile || currentValuesReadable else {
            return .skip(message: "Could not read the current Low Power Mode values; it was left unchanged.")
        }
        if hasSavedLowPowerFile, !savedLowPowerValid {
            return .skip(message: "Saved Low Power Mode state is invalid; it was left unchanged.")
        }
        return .attempt
    }

    /// Whether configured automatic limits should be evaluated for this
    /// snapshot. An unreadable lid probe is not enough to force a change by
    /// itself, but it also must not cancel an already-configured deadline when
    /// PID/timestamp state proves that Lidless has a tracked session.
    static func shouldEvaluateAutoOffLimits(
        lidPresentation: LidPresentation,
        hasSessionEvidence: Bool
    ) -> Bool {
        switch lidPresentation {
        case .ignored:
            return true
        case .normal:
            return false
        case .unknown:
            return hasSessionEvidence
        }
    }

    /// How long a panel heartbeat may go untouched before its owner is presumed
    /// hung. Lives here because both binaries need it: the rescue tool decides
    /// whether to sweep, and the app decides at launch whether a heartbeat it
    /// found belongs to a live instance. `DisplayRescue.heartbeatStaleAfter` is
    /// this value — the reasoning for the number is documented there.
    static let panelHeartbeatStaleAfter: TimeInterval = 25

    /// What a heartbeat file found at app launch means.
    enum StrandedHeartbeatVerdict: Equatable {
        /// No file, or one nobody has touched for longer than a live owner ever
        /// would. Safe to delete and to adopt whatever marker is beside it.
        case leftover
        /// Something is still writing to it. Almost certainly a second instance
        /// of this app holding a blackout right now.
        case liveOwner
    }

    /// Whether a heartbeat file present at launch is a leftover this instance may
    /// delete.
    ///
    /// The launch path used to delete it unconditionally, on the stated premise
    /// that "this app has just started and is holding nothing, so nothing is
    /// writing to it". That is a single-instance assumption, and nothing enforces
    /// single-instance — `open -n`, running the binary in `build/` directly, or a
    /// second copy in `~/Applications` all produce two. Instance #2 deleted
    /// instance #1's heartbeat; #1's watchdog then read the missing file as
    /// infinitely stale and swept a working blackout out from under it.
    ///
    /// A negative age (the clock moved backwards) counts as **live** here, which
    /// is the opposite of how `DisplayRescue` treats the same reading — and
    /// deliberately so. There, not firing costs the screen; here, deleting costs
    /// somebody else's screen. Each errs away from its own worst outcome.
    static func strandedHeartbeatDecision(
        age: TimeInterval?,
        staleAfter: TimeInterval = SystemProbe.panelHeartbeatStaleAfter
    ) -> StrandedHeartbeatVerdict {
        guard let age: TimeInterval = age else { return .leftover }
        if age < 0 { return .liveOwner }
        return age >= staleAfter ? .leftover : .liveOwner
    }

    /// Whether the screen-lock restore point has done its job and may be
    /// deleted.
    ///
    /// Three conditions, and the third is the one that was missing. The app
    /// releases the interprocess lock before the Terminal password wait — it must,
    /// a cross-process lock cannot be held across a human — but that left the
    /// restore point unguarded for the whole 30-second window, and a concurrent
    /// `lidless.sh off` (which holds that lock for its entire `off()`) could
    /// delete it while `sysadminctl` had not yet applied anything. The Mac then
    /// never locked its screen again, with nothing on disk to undo it.
    ///
    /// So deletion now happens under the lock, and **failing to take the lock
    /// means keeping the file**. The two errors are not symmetric: a restore
    /// point kept too long is one stale file and a restore that no-ops, while a
    /// restore point deleted too early is a relaxed screen lock that only an
    /// account password can put back.
    static func screenLockRestorePointIsSpent(
        commandApplied: Bool,
        savingCurrent: Bool,
        lockHeld: Bool
    ) -> Bool {
        // `savingCurrent` means this call CREATED the restore point moments ago;
        // consuming it here would throw away the value it just saved.
        commandApplied && !savingCurrent && lockHeld
    }

    /// Why an automatic shutdown was armed. Carried through the grace period so
    /// the condition can be re-checked at the end of it — the countdown used to
    /// carry only its own display string, which is not something you can
    /// re-evaluate.
    enum AutomaticShutdownTrigger: Equatable {
        case hours(Int)
        case batteryPercent(Int)

        /// The wording the notification and the note both use, so the two cannot
        /// drift. The percentage is the one measured when the countdown started;
        /// the re-check below uses the live reading, not this.
        var reason: String {
            switch self {
            case .hours(let hours): return "after \(hours)h"
            case .batteryPercent(let percent): return "battery at \(percent)%"
            }
        }
    }

    /// Whether the condition that armed an automatic shutdown still holds now
    /// that the grace period has expired.
    ///
    /// Neither side of this feature used to ask. The app slept 60 s and powered
    /// off on the reason string captured at arm time; the watchdog slept its
    /// grace and consulted only the cancel file. So the obvious response to
    /// "battery at 12%" — plugging the charger in — did not stop the shutdown,
    /// and the Mac powered off on mains at a rising charge.
    ///
    /// Mirrors the shell's `auto_off_reason` (`lidless.sh`), which the watchdog
    /// now re-runs against a fresh `pmset -g ps` for the same reason.
    ///
    /// Both arms re-read the *limit* as well as the reading, so clearing the
    /// limit during the grace also abandons the shutdown.
    static func automaticShutdownStillWarranted(
        trigger: AutomaticShutdownTrigger,
        hasSessionEvidence: Bool,
        sessionElapsed: TimeInterval?,
        hoursLimit: Int,
        powerSourceReadable: Bool,
        onBattery: Bool,
        batteryPercent: Int?,
        batteryThreshold: Int
    ) -> Bool {
        switch trigger {
        case .hours:
            guard hoursLimit > 0, hasSessionEvidence, let elapsed: TimeInterval = sessionElapsed
            else { return false }
            return elapsed >= Double(hoursLimit) * 3600
        case .batteryPercent:
            guard batteryThreshold > 0, powerSourceReadable, onBattery,
                  let percent: Int = batteryPercent
            else { return false }
            return percent <= batteryThreshold
        }
    }

    /// Whether a `pmset -g batt` response is one this app can trust, and (if
    /// so) whether it means the Mac is on battery. Pure and directly
    /// testable without shelling out — a malformed-but-nonempty,
    /// status-zero response with NEITHER expected header used to be marked
    /// "readable" anyway and then silently fold to AC via the
    /// `.contains("Battery Power")` check alone finding nothing. See
    /// docs/ARCHITECTURE.md (review round 1).
    static func powerSourceResult(status: Int32, output: String) -> (readable: Bool, onBattery: Bool) {
        // Exactly one whole line matching the canonical phrase, not a
        // substring match anywhere in the text — `.contains(...)` on the
        // full phrase is still vulnerable to a diagnostic message that
        // happens to quote it, or to output containing both phrases (which
        // checking Battery first would silently resolve to "battery"
        // without noticing the contradiction). See
        // docs/ARCHITECTURE.md — review round 3 (round
        // 2's fix anchored on the phrase but was still `.contains`).
        guard status == 0 else { return (false, false) }
        let matches = output.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0 == "Now drawing from 'AC Power'" || $0 == "Now drawing from 'Battery Power'" }
        guard matches.count == 1 else { return (false, false) }
        return (true, matches[0] == "Now drawing from 'Battery Power'")
    }

    /// Whether this Mac has a battery, from two independent reads (`-g
    /// custom`'s "Battery Power" section, `-g batt`'s "InternalBattery"
    /// entry) — a `-g custom` response missing "Battery Power" could mean a
    /// genuine desktop, or that the output was truncated right at the
    /// section boundary; cross-checking against the other command catches
    /// the disagreement instead of confidently concluding "no battery" from
    /// one ambiguous read. Both underlying probes must have actually
    /// succeeded (status 0) for anything but `.unknown`. See
    /// docs/ARCHITECTURE.md — review round 3.
    static func batteryPresenceResult(
        customStatus: Int32, custom: String,
        batteryStatus: Int32, batteryInfo: String
    ) -> BatteryPresence {
        if customStatus == 0, custom.contains("Battery Power") {
            return .yes
        }
        if batteryStatus == 0, batteryInfo.contains("InternalBattery") {
            return .yes
        }
        // Confirming "no battery" from batteryInfo needs more than a status-0
        // exit — a status-0 call that returned empty or malformed text must
        // not read as "confirmed no InternalBattery" merely because the
        // literal substring happens to be absent from garbage. Mirrors
        // lidless.sh's battery_entry_presence(), which requires one of the
        // canonical "Now drawing from '...'" lines before trusting the
        // absence check. review round 4.
        if customStatus == 0, custom.contains("AC Power"),
           powerSourceResult(status: batteryStatus, output: batteryInfo).readable {
            return .no
        }
        return .unknown
    }

    /// Battery current and whether the Mac is losing charge while plugged in,
    /// from one `ioreg -rn AppleSmartBattery` read.
    ///
    /// **`InstantAmperage` is unsigned.** A discharge of −820 mA arrives as
    /// `18446744073709550796`, which is 2^64 − 820. Anything above 2^63 is a
    /// negative number that has to be brought back; reading it as written gives
    /// a plausible-looking enormous positive current, which is exactly the
    /// silent-wrong-number failure this whole feature is built to avoid. Found
    /// by cross-checking against the SMC on 2026-08-05 (docs/SMC_SENSORS.md §4).
    ///
    /// "Draining on AC" needs all three of: external power connected, not
    /// charging, and a negative current. `IsCharging = No` alone is not enough —
    /// a full battery on AC reads exactly that, with a current of zero. The
    /// state being reported is a 35 W adapter that cannot cover a 21 W SoC plus
    /// the rest of the machine, and only the negative current says so.
    ///
    /// A missing `AppleSmartBattery` node — a desktop — is not readable rather
    /// than "not draining": there is nothing to warn about, but there is also
    /// nothing that was checked.
    /// `watts` is the battery rail's power, **signed**: positive going into the
    /// battery, negative coming out, zero when it is neither. Current times
    /// voltage, both from the same read.
    ///
    /// That product is not a guess. The cross-check in `docs/SMC_SENSORS.md` §4
    /// is exactly this arithmetic — −820 mA at 12.59 V is 10.3 W, against the
    /// SMC's own `PPBR` reading 10.6 W in the same moment. What is verified is
    /// the discharge direction. **Charging was never observed** on the only
    /// machine available: optimised charging held the battery at 85 % with
    /// `IsCharging = No` throughout (§6). The formula is symmetric and the sign
    /// comes straight from the current, so a positive reading is the same
    /// arithmetic run the other way — but it has not been seen against real
    /// hardware, and `docs/ARCHITECTURE.md` §9 says so.
    static func batteryDrainResult(
        status: Int32,
        output: String
    ) -> (readable: Bool, milliamps: Int?, watts: Double?, drainingOnAC: Bool,
          externalConnected: Bool?) {
        guard status == 0 else { return (false, nil, nil, false, nil) }
        guard let raw: UInt64 = ioregUnsignedValue(in: output, key: "InstantAmperage") else {
            return (false, nil, nil, false, ioregYesNo(in: output, key: "ExternalConnected"))
        }
        // The two-step conversion is deliberate: UInt64 -> Int64 by bit
        // pattern, which is the same wraparound the driver applied, and only
        // then to Int. Subtracting 2^64 in Double would lose precision at
        // exactly the magnitudes involved.
        let milliamps = Int(Int64(bitPattern: raw))
        // `Voltage` is in millivolts, and it is deliberately read by the same
        // anchored matcher as everything else: the `BatteryData` blob is one
        // enormous line containing `"Voltage"=12608` among fifty other keys,
        // and an unanchored search finds that first.
        let millivolts: UInt64? = ioregUnsignedValue(in: output, key: "Voltage")
        let watts: Double? = millivolts.map { Double(milliamps) * Double($0) / 1_000_000 }
        let onExternal: Bool? = ioregYesNo(in: output, key: "ExternalConnected")
        let charging: Bool? = ioregYesNo(in: output, key: "IsCharging")
        guard let onExternal: Bool = onExternal, let charging: Bool = charging else {
            // The current alone does not say whether losing charge is expected.
            return (false, milliamps, watts, false, nil)
        }
        return (true, milliamps, watts, onExternal && !charging && milliamps < 0, onExternal)
    }

    /// What the connected power adapter is rated at, in watts, from the same
    /// `ioreg -rn AppleSmartBattery` read as `batteryDrainResult`.
    ///
    /// nil means no adapter, or nothing that could be read: on this Mac the
    /// value comes from `AdapterDetails`, which is an empty dictionary when the
    /// machine is on battery. It is a **rating**, not a measurement — the label
    /// on the brick, which is exactly what makes it worth showing next to the
    /// battery's actual draw. A 35 W rating beside a 21 W SoC is how the
    /// AC-drain state in §4 of `docs/SMC_SENSORS.md` stops being a surprise.
    ///
    /// `AdapterDetails` is one long dictionary on a single line, not a `"Key" =
    /// value` line of its own, so it cannot use the line matcher below. Anchored
    /// on `"AdapterDetails" = {` rather than on `"Watts"` anywhere in the text:
    /// `AppleRawAdapterDetails` carries a `Watts` of its own thirty-six lines
    /// earlier, and an unanchored search finds that one first.
    static func adapterWattsResult(status: Int32, output: String) -> Int? {
        guard status == 0 else { return nil }
        let anchor = "\"AdapterDetails\" = {"
        for line: Substring in output.split(separator: "\n") {
            guard let start: Substring.Index = line.range(of: anchor)?.upperBound else { continue }
            let body: Substring = line[start...]
            guard let wattsStart: Substring.Index = body.range(of: "\"Watts\"=")?.upperBound else {
                return nil
            }
            let digits: Substring = body[wattsStart...].prefix { $0.isNumber }
            guard !digits.isEmpty, let watts = Int(digits), watts > 0 else { return nil }
            return watts
        }
        return nil
    }

    /// One `"Key" = 123` line from `ioreg` output, as written and unsigned.
    ///
    /// Anchored on the quoted key so a key that is a suffix of another
    /// (`"Amperage"` inside `"InstantAmperage"`) cannot match — the plain
    /// `contains` form would pick whichever came first in the text.
    private static func ioregUnsignedValue(in output: String, key: String) -> UInt64? {
        let needle = "\"\(key)\" = "
        for line: Substring in output.split(separator: "\n") {
            let trimmed: Substring = line.drop { $0 == " " || $0 == "|" || $0 == "+" }
            guard trimmed.hasPrefix(needle) else { continue }
            let value: Substring = trimmed.dropFirst(needle.count)
            return UInt64(value.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// One `"Key" = Yes|No` line, anchored the same way.
    private static func ioregYesNo(in output: String, key: String) -> Bool? {
        let needle = "\"\(key)\" = "
        for line: Substring in output.split(separator: "\n") {
            let trimmed: Substring = line.drop { $0 == " " || $0 == "|" || $0 == "+" }
            guard trimmed.hasPrefix(needle) else { continue }
            switch trimmed.dropFirst(needle.count).trimmingCharacters(in: .whitespaces) {
            case "Yes": return true
            case "No": return false
            default: return nil
            }
        }
        return nil
    }

    static func isCaffeinateProcess(_ pid: Int) -> Bool {
        guard pid > 0 else { return false }
        let result = Shell.run(Shell.Command(
            "/bin/ps",
            ["-p", String(pid), "-o", "comm="]
        ))
        return isCaffeinateProcessResult(status: result.status, output: result.output)
    }

    /// The name-matching half of `isCaffeinateProcess`, split out for the same
    /// reason as its immediate neighbour `caffeinatePIDQueryResult`: fused to
    /// `Shell.run`, the rule was unreachable from a test, and this rule decides
    /// whether the app believes a recorded PID is still the `caffeinate` it
    /// started. `ps -o comm=` may print a full path or leave trailing
    /// whitespace, and the shell's own `is_caffeinate_pid` must agree about both.
    static func isCaffeinateProcessResult(status: Int32, output: String) -> Bool {
        guard status == 0 else { return false }
        let trimmed: String = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return URL(fileURLWithPath: trimmed).lastPathComponent == "caffeinate"
    }

    /// Returns the current user's caffeinate PIDs from one process-table
    /// snapshot without folding an enumeration failure into "no processes".
    /// Callers that act on found PIDs still re-check every process after
    /// signalling it.
    static func caffeinatePIDQuery() -> CaffeinatePIDQueryResult {
        let result: (status: Int32, output: String) = Shell.run(Shell.Command(
            "/usr/bin/pgrep",
            ["-u", String(getuid()), "-x", "caffeinate"]
        ))
        return caffeinatePIDQueryResult(status: result.status, output: result.output)
    }

    /// Pure parser for pgrep's contract: 0 means matches, 1 means no matches,
    /// and every other status is an execution/enumeration failure. A successful
    /// response with malformed or empty output is also a failure because a
    /// partial target set would make stop-all's success claim untrustworthy.
    static func caffeinatePIDQueryResult(
        status: Int32,
        output: String
    ) -> CaffeinatePIDQueryResult {
        if status == 1 {
            return .none
        }
        guard status == 0 else {
            return .failed
        }

        let values: [Substring] = output.split(whereSeparator: { character in
            character.isWhitespace
        })
        guard !values.isEmpty else {
            return .failed
        }

        var pids: [Int] = []
        pids.reserveCapacity(values.count)
        for value: Substring in values {
            guard let pid: Int = Int(value), pid > 0 else {
                return .failed
            }
            pids.append(pid)
        }
        return .found(pids)
    }

    /// Reads the live lid setting. Nil means the probe failed or returned an
    /// unexpected shape; callers performing a destructive action must stop in
    /// that case instead of assuming the safe value is false.
    ///
    /// Routes through `sleepDisabledValue(in:)` directly rather than the
    /// folding `sleepDisabled(in:)` wrapper — that fold used to make a
    /// present-but-garbage value silently read as "not ignored", which this
    /// method's own doc comment claimed (incorrectly, until this fix) was
    /// already handled. Real output is never empty; a genuinely empty result
    /// means the probe produced nothing, distinct from a well-formed result
    /// where the key is legitimately absent (see sleepDisabledValue).
    static func lidIgnored() -> Bool? {
        let result = Shell.run(Shell.Command("/usr/bin/pmset", ["-g"]))
        return lidIgnoredResult(status: result.status, output: result.output)
    }

    /// The status-check-and-routing half of lidIgnored(), split out so it is
    /// directly testable without shelling out to the real `pmset` — proving
    /// this routes through sleepDisabledValue(in:) directly rather than the
    /// folding sleepDisabled(in:) wrapper, which is the actual bug this
    /// method used to have. See docs/ARCHITECTURE.md
    /// (review round 1).
    static func lidIgnoredResult(status: Int32, output: String) -> Bool? {
        guard status == 0, !output.isEmpty else { return nil }
        return sleepDisabledValue(in: output)
    }

    /// Splits on any run of whitespace, the way awk's default field splitting
    /// does. `pmset -g` separates its columns with tabs while `pmset -g custom`
    /// uses runs of spaces, so splitting on a literal " " silently misreads one
    /// of them.
    private static func fields(_ line: Substring) -> [Substring] {
        line.split(whereSeparator: { $0.isWhitespace })
    }

    /// Reads `SleepDisabled` from `pmset -g`. Absent reads as false.
    static func sleepDisabled(in text: String) -> Bool {
        sleepDisabledValue(in: text) ?? false
    }

    /// Real `pmset -g` output only ever prints the SleepDisabled line when it
    /// is 1 — a normal Mac (SleepDisabled=0) omits the key entirely. This is
    /// confirmed by Apple's own open-source pmset.c,
    /// show_system_power_settings(): it only prints the line when the key
    /// exists in the settings dictionary, i.e. only once it has actually been
    /// set — NOT inferred from tests/fixtures/pmset-g-sleepdisabled-off.txt,
    /// which is synthetic (tests/fixtures/README.md; an earlier version of
    /// this comment wrongly called it a real capture). So a missing key is
    /// the ordinary case and reads `false`, not nil — nil is reserved for a
    /// present-but-garbage value (truncated, corrupted, anything but exactly
    /// "1" or "0"), which is genuinely ambiguous. Mirrors lidless.sh's
    /// parse_sleep_disabled.
    static func sleepDisabledValue(in text: String) -> Bool? {
        // First field exactly "SleepDisabled", not a substring match — the
        // latter would also match an unrelated key like "NotSleepDisabled".
        // See docs/ARCHITECTURE.md — review round 2.
        let matches = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { fields($0).first == "SleepDisabled" }
        // More than one matching row is ambiguous, not "pick one" — shell's
        // awk used to silently keep overwriting its `value` variable (last
        // row wins) while this used to `return` on the first match, so the
        // two languages disagreed on genuinely duplicated/contradictory
        // output instead of both calling it unknown. review round 4.
        guard matches.count <= 1 else { return nil }
        guard let line = matches.first else { return false }
        let parts = fields(line)
        // Exactly two fields (key + value) — awk's shell equivalent reads $2
        // the same way. A stray extra token ("SleepDisabled garbage 1") used
        // to fall through to `.last`, so shell and Swift disagreed about a
        // malformed line. review round 3.
        guard parts.count == 2 else { return nil }
        if parts[1] == "1" { return true }
        if parts[1] == "0" { return false }
        return nil
    }

    /// The two names `pmset -g custom` gives the one Low Power Mode setting.
    /// macOS 26 prints `lowpowermode` (tests/fixtures/pmset-custom-macbook.txt
    /// is a real capture from 26.5.2); macOS 15 and earlier print `powermode`
    /// for the very same value — `pmset -a lowpowermode 1` writes it and
    /// `pmset -g custom` reads it back under the other name. Reading only the
    /// first name made every Low Power Mode reading on macOS 15 "Unknown", and
    /// with it the tile, the Enable-time save, and the Disable-time restore.
    /// Keep in sync with lidless.sh's parse_lowpower_field.
    private static let lowPowerKeys: Set<String> = ["lowpowermode", "powermode"]

    /// Reads Low Power Mode from one section of `pmset -g custom`, without
    /// assuming any section exists or that they appear in a fixed order.
    ///
    /// Desktops print no "Battery Power:" section at all. An earlier version
    /// scanned a fixed range between the two headers and read empty on them.
    static func lowPower(in custom: String, section: String) -> Bool {
        lowPowerValue(in: custom, section: section) ?? false
    }

    /// Like lowPower(in:section:), but nil when the (section, key)
    /// pair was never actually found — whether because the section itself is
    /// missing (possibly truncated output, not necessarily a real desktop)
    /// or the key within it is. lowPower(in:section:)'s `false` default is
    /// fine for display purposes; it is NOT fine for performEnable's Low
    /// Power Mode save, which used to silently write a fabricated "original
    /// value" on an unreadable read, corrupting the later restore. See
    /// docs/ARCHITECTURE.md — review round 2.
    static func lowPowerValue(in custom: String, section: String) -> Bool? {
        var inSection = false
        for rawLine in custom.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("Power:") {
                inSection = line.contains(section)
                continue
            }
            let parts = fields(line[...])
            if inSection, let key = parts.first, lowPowerKeys.contains(String(key)) {
                // Exactly two fields, reading field two — matching shell's
                // awk `$1 == key { val = $2 }` exactly. Reading `parts.last`
                // disagreed with shell on a stray extra token: shell's `$2`
                // and Swift's `.last` pick different fields once a row has
                // more than two ("lowpowermode garbage 1" read unknown in
                // shell but confirmed-on here). review round 4.
                //
                // The FIRST line carrying either name decides, malformed
                // included — not "try lowpowermode, then fall back to
                // powermode". A malformed row means the output cannot be
                // trusted, and falling back would turn it into a confirmed
                // reading from a different line; shell's awk (one pass, one
                // `seen` flag over both names) behaves the same way.
                guard parts.count == 2 else { return nil }
                if parts[1] == "1" { return true }
                if parts[1] == "0" { return false }
                // `powermode 2` is High Power Mode, which Lidless has no way
                // to save or put back: the restore only ever writes
                // `lowpowermode 0/1`, so calling this a confirmed "off" would
                // quietly demote a high-power Mac to normal on Disable. Read
                // as unconfirmed instead — that already means "show Unknown,
                // do not save, do not touch it" everywhere downstream.
                return nil
            }
        }
        return nil
    }

    /// Reads the charge percentage from `pmset -g batt`. Nil on a machine with
    /// no battery.
    static func batteryPercent(in text: String) -> Int? {
        guard let range = text.range(of: #"[0-9]+%"#, options: .regularExpression) else { return nil }
        return Int(text[range].dropLast())
    }

    /// Reads the time estimate from `pmset -g batt`:
    ///
    ///     18%; discharging; 1:04 remaining present: true
    ///     85%; charging; 1:23 remaining present: true
    ///     85%; AC attached; not charging present: true
    ///
    /// The state words overlap as substrings — `discharging` contains `charging`,
    /// and so does `not charging` — so the order of these checks is the parser.
    /// Test it before rearranging them.
    static func batteryTime(in text: String) -> BatteryTime {
        let lower: String = text.lowercased()
        guard lower.contains("%") else { return .unknown }

        let estimate: String? = {
            guard let range = lower.range(of: #"[0-9]+:[0-9]{2}(?= remaining)"#,
                                          options: .regularExpression) else { return nil }
            return String(lower[range])
        }()
        let noEstimate: Bool = lower.contains("no estimate")

        if lower.contains("discharging") {
            if let estimate { return .remaining(estimate) }
            return noEstimate ? .estimating : .unknown
        }
        if lower.contains("not charging") { return .notCharging }
        // Checked before `charging`: a charged battery also reports `0:00
        // remaining`, which would otherwise render as "0:00 to full".
        if lower.contains("charged") { return .charged }
        if lower.contains("charging") || lower.contains("finishing charge") {
            if let estimate { return .toFull(estimate) }
            return noEstimate ? .estimating : .unknown
        }
        return .unknown
    }

    /// `ioreg -r -k AppleClamshellState` prints `"AppleClamshellState" = Yes`
    /// when the lid is shut. Match the key's own line: the surrounding output
    /// is full of unrelated `Yes` values.
    /// Suffix of the file the recovery watchdog creates the moment it reaches its
    /// watch loop, appended to the heartbeat path. It lives here because the app
    /// and the watchdog are two separate binaries that share only this file and
    /// `VirtualDisplay.swift`; a literal in each would be the same contract
    /// written twice, and the failure if they drifted is silent — the app would
    /// wait for a file nobody writes and refuse every blackout.
    static let displayWatchdogReadySuffix = ".ready"

    static func clamshellClosed(in text: String) -> Bool {
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false)
        where rawLine.contains("AppleClamshellState") {
            return rawLine.contains("Yes")
        }
        return false
    }

    static func screenLock() -> String {
        screenLock(in: Shell.output(Shell.Command(
            "/usr/sbin/sysadminctl",
            ["-screenLock", "status"]
        )))
    }

    /// Parses `sysadminctl -screenLock status` output, which the tool writes to
    /// stderr. Returns off | immediate | <seconds> | unknown.
    ///
    /// "unknown" also covers the refusal case ("Password is required!"), which
    /// must never be mistaken for a real value — the tool exits 0 either way.
    static func screenLock(in out: String) -> String {
        let lower = out.lowercased()
        if out.isEmpty { return "unknown" }
        if lower.contains("is off") { return "off" }
        if lower.contains("immediate") { return "immediate" }
        if let range = out.range(of: #"[0-9]+ seconds"#, options: .regularExpression) {
            return String(out[range]).replacingOccurrences(of: " seconds", with: "")
        }
        return "unknown"
    }

    /// Validates a value stored in ~/.lidless_screenlock_prev and returns a
    /// canonical representation safe to pass as one argv element.
    static func savedScreenLock(in text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "off" || value == "immediate" {
            return value
        }
        guard let seconds = Int(value), seconds >= 0 else { return nil }
        return String(seconds)
    }

    /// Validates ~/.lidless_lowpower_prev, stored as "ac:battery".
    static func savedLowPower(in text: String) -> (ac: Int, battery: Int)? {
        let parts = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let ac = Int(parts[0]),
              let battery = Int(parts[1]),
              (ac == 0 || ac == 1),
              (battery == 0 || battery == 1) else {
            return nil
        }
        return (ac, battery)
    }

    /// Parses the canonical Unix timestamp shared by the app, shell script and
    /// LaunchAgent. Rejecting zero, negative and malformed values prevents a
    /// corrupt state file from firing a nonsensical deadline.
    static func enabledAt(in text: String) -> Date? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let seconds = Int64(value), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    // MARK: - Panel blackout

    /// What `PanelMode.dim` takes the panel down to. Deliberately not zero.
    ///
    /// It briefly looked dead: `.virtualDisplay` stopped dimming on 2026-08-02
    /// once disabling the display turned out to switch the backlight off by
    /// itself (docs/ARCHITECTURE.md). `.dim` makes it load-bearing again,
    /// and more so than before — that mode has no display disable to fall back
    /// on, so this value is the entire effect.
    ///
    /// Measured 2026-08-01 on this panel: 0.0 drives the backlight register to a
    /// literal 0, while 0.01 and 0.05 both land on the same hardware minimum
    /// (131211 against a maximum of 24.4 million — half a percent). With the lid
    /// shut the two are indistinguishable. They differ completely after a crash:
    /// macOS persists brightness across reboots, so a panel left at 0.0 boots
    /// into a black screen that reads as dead hardware, and one left here boots
    /// dim but legible. In `.dim` that is the ONLY thing standing between a crash
    /// and a screen its owner will think is broken — nothing else about that mode
    /// needs undoing, so nothing else would prompt anyone to look.
    static let panelDimLevel: Float = 0.01

    /// At or above this the screen can be read, so recovery must not touch it.
    static let panelVisibleFloor: Float = 0.02

    /// Used only when there is no trustworthy value to put back. Modest on
    /// purpose: it overrides a choice the user made, so it should be enough to
    /// see by and no more.
    static let panelFallbackBrightness: Float = 0.3

    /// Validates ~/.lidless_display_prev, which holds one brightness and nothing
    /// else — the same shape as `.lidless_screenlock_prev` and
    /// `.lidless_lowpower_prev`. Owner liveness lives in its own file, the way
    /// `.lidless_caffeinate_pid` does.
    ///
    /// Be precise about WHICH brightness: whatever the panel read at the instant
    /// blackout took it over, which is not reliably the level the person was
    /// working at. Blackout runs after the lid has started closing, and macOS is
    /// often part-way through its own fade by then. Measured across cycles:
    ///
    ///   2026-08-01  0.256 captured, working level ~0.56   (mid-fade)
    ///   2026-08-01  0.360 captured, working level ~0.84   (mid-fade)
    ///   2026-08-02  0.49997443 captured, working level 0.49997443  (exact)
    ///
    /// So the capture is variable, and the only claim true of every case is the
    /// weak one: a legible level to come back to, not a restoration of anyone's
    /// setting. `panelBrightnessDecision` is built around exactly that — it
    /// prefers to leave an already-legible screen alone rather than write this
    /// value over it.
    ///
    /// Since 2026-08-02 the normal path never reads this back: blackout does not
    /// change brightness, so there is nothing to undo. It survives for recovery,
    /// where a panel is found dark and something has to be put back.
    static func savedDisplayBrightness(in text: String) -> Float? {
        // New markers may carry `virtualDisplayID=` on their second line. Reading
        // only the first keeps every one-line marker from older builds valid.
        guard let firstLine = text.split(whereSeparator: \Character.isNewline).first else {
            return nil
        }
        let value = firstLine.trimmingCharacters(in: .whitespaces)
        guard let level = Float(value), level.isFinite, level >= 0, level <= 1 else {
            return nil
        }
        return level
    }

    /// The exact carrier owned by the blackout that wrote this marker. Display
    /// IDs are not stable across reboot, so callers must also confirm the ID is
    /// currently present and virtual before acting on it.
    static func savedVirtualDisplayID(in text: String) -> UInt32? {
        let prefix = "virtualDisplayID="
        let matches = text.split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(prefix) }
        guard matches.count == 1 else { return nil }
        let value = matches[0].dropFirst(prefix.count)
        guard !value.isEmpty, value.allSatisfy(\.isNumber) else { return nil }
        return UInt32(value)
    }

    static func displayRestoreMarker(brightness: Float, virtualDisplayID: UInt32?) -> String {
        var text = "\(brightness)\n"
        if let virtualDisplayID { text += "virtualDisplayID=\(virtualDisplayID)\n" }
        return text
    }

    /// Whether the built-in panel may be disabled right now.
    ///
    /// The whole safety invariant of Panel blackout is this function: never take
    /// away the display a human is looking at unless another one is CONFIRMED to
    /// be carrying the session. `displays == nil` means the list could not be
    /// read, which is never a licence to blind the Mac — unlike
    /// `panelBrightnessDecision` below, where an unreadable probe permits the
    /// action because the action only ever makes the screen visible again.
    static func blackoutDecision(
        activeDisplayIDs: [UInt32]?,
        builtinID: UInt32?,
        virtualDisplayID: UInt32?
    ) -> BlackoutDecision {
        guard let activeDisplayIDs else {
            return .refuse(reason: "the list of active displays could not be read")
        }
        guard let builtinID else {
            return .refuse(reason: "no built-in display was found")
        }
        guard let virtualDisplayID else {
            return .refuse(reason: "no virtual display was created")
        }
        guard virtualDisplayID != builtinID else {
            return .refuse(reason: "the virtual display reported the built-in's own ID")
        }
        guard activeDisplayIDs.contains(builtinID) else {
            return .refuse(reason: "the built-in display is not active to begin with")
        }
        guard activeDisplayIDs.contains(virtualDisplayID) else {
            return .refuse(reason: "the virtual display is not in the active list")
        }
        let others = activeDisplayIDs.filter { $0 != builtinID }
        guard !others.isEmpty else {
            return .refuse(reason: "no display other than the built-in is active")
        }
        return .proceed(builtinID: builtinID)
    }

    /// Returns the mode size that preserves the built-in panel's current
    /// workspace size. On arm64, CGVirtualDisplay's HiDPI setting halves the
    /// physical pixel dimensions into points. On Intel it does not: supplying
    /// the physical 3072x1920 panel size there produces a 3072x1920 1x desktop
    /// instead of the panel's current scaled workspace (for example 1792x1120).
    static func virtualDisplayModeDimensions(
        logicalWidth: Int,
        logicalHeight: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        usesPhysicalPixelMode: Bool
    ) -> VirtualDisplayModeDimensions? {
        guard logicalWidth > 0, logicalHeight > 0,
              pixelWidth > 0, pixelHeight > 0 else { return nil }
        return usesPhysicalPixelMode
            ? VirtualDisplayModeDimensions(width: pixelWidth, height: pixelHeight)
            : VirtualDisplayModeDimensions(width: logicalWidth, height: logicalHeight)
    }

    /// Intel needs the restore deferred while the lid is physically closed. The
    /// caller decides what "deferred" means: normal reconciliation returns and
    /// tries again on the lid event; termination stays alive and waits for it.
    static func panelRestoreSchedule(
        isIntel: Bool,
        usesVirtualCarrier: Bool,
        hasLid: Bool,
        lidClosed: Bool
    ) -> PanelRestoreSchedule {
        isIntel && usesVirtualCarrier && hasLid && lidClosed
            ? .waitForLidOpen
            : .now
    }

    /// IDs a recovery sweep should explicitly enable. CGDirectDisplayID is an
    /// opaque UInt32, not a small ordinal: the Intel incident that motivated this
    /// returned 69734662 before the blackout and 1104977157 after re-enumeration.
    /// Keep the legacy low-ID sweep as a fallback, but put the attached built-in
    /// first so recovery can act on the display that actually exists.
    static func displayRescueCandidateIDs(
        builtinID: UInt32?,
        legacyUpperBound: UInt32
    ) -> [UInt32] {
        var result: [UInt32] = []
        if let builtinID { result.append(builtinID) }
        guard legacyUpperBound > 0 else { return result }
        for id in 1...legacyUpperBound where id != builtinID {
            result.append(id)
        }
        return result
    }

    /// What to do about brightness while putting the panel back.
    ///
    /// This is the one decision in the project where an unreadable probe PERMITS
    /// the action rather than blocking it. The action only makes a screen legible,
    /// so failing closed here would mean failing in favour of a dark screen and a
    /// person who cannot see why. Do not "fix" this to match the others.
    static func panelBrightnessDecision(
        savedValue: Float?,
        currentValue: Float?
    ) -> PanelBrightnessDecision {
        if let currentValue, currentValue.isFinite, currentValue >= panelVisibleFloor {
            return .leaveAlone
        }
        guard let savedValue, savedValue.isFinite,
              savedValue >= panelVisibleFloor, savedValue <= 1 else {
            return .restore(panelFallbackBrightness)
        }
        return .restore(savedValue)
    }

    /// How the panel should be described, given what could be established about it.
    /// `builtinActive == nil` means the display list was unreadable.
    /// **Mode-independent on purpose, and that was not obvious.** A `mode:`
    /// parameter was added here and removed the same day: mutation testing showed
    /// deleting the entire `.dim` branch changed no answer on any input, because
    /// the two branches are the same function written twice. The reasoning below
    /// covers both modes, so re-adding a mode split would be adding a second
    /// spelling of one rule.
    ///
    /// `.virtualDisplay` leaves the built-in inactive with an unreadable
    /// brightness; `.dim` leaves it active at `panelDimLevel`. Both land on
    /// "not lit" here without being told which happened.
    ///
    /// Ownership decides `.dark` versus `.stranded`, and nothing else here.
    static func panelPresentation(
        builtinActive: Bool?,
        brightness: Float?,
        blackoutOwnedByThisApp: Bool
    ) -> PanelPresentation {
        guard let builtinActive else { return .unknown }
        let dim = brightness.map { $0 < panelVisibleFloor }
        if builtinActive {
            // Readably bright. Lit, whoever owns it — including a `.virtualDisplay`
            // blackout that lapsed and handed the panel back by itself, which is a
            // state this must keep reporting as lit rather than as anything more
            // alarming.
            if dim == false { return .lit }

            // Brightness unreadable, so nothing confident can be said: `.dim`
            // leaves the built-in active and its level is the only evidence of
            // anything at all. Silence is not evidence of a dark screen, but it is
            // not evidence of a lit one either, and this project does not report
            // a probe that returned nothing as a fact anywhere else.
            //
            // The old rule here was `.lit`, guarding against a real bug: reading
            // an unreadable brightness as darkness painted a healthy panel red
            // with "stranded — press Restore". That guard was aimed at the wrong
            // value. `.stranded` is the red one; `.unknown` is amber, and only
            // when blackout is armed — and a Mac whose brightness never reads
            // cannot arm a blackout in the first place, because both modes need a
            // readable level to write the marker before they touch anything.
            if dim == nil { return .unknown }
        }
        guard blackoutOwnedByThisApp else { return .stranded }
        return .dark
    }

    /// Whether the panel may be dimmed right now — `.dim`'s counterpart to
    /// `blackoutDecision`, and deliberately a separate function rather than a flag
    /// on that one.
    ///
    /// The two guard different things. `blackoutDecision` protects against
    /// blinding the Mac, so it refuses on any doubt: an unreadable display list is
    /// never a licence to take a screen away. Dimming cannot take a screen away —
    /// the display stays in the configuration and the brightness key still works —
    /// so the only real question is whether the write would land at all. Folding
    /// them together would mean either dimming inherits refusals it does not need,
    /// or blackout loses one it does.
    static func dimDecision(
        builtinID: UInt32?,
        builtinActive: Bool?,
        canChangeBrightness: Bool
    ) -> BlackoutDecision {
        guard let builtinID else {
            return .refuse(reason: "no built-in display was found")
        }
        guard builtinActive == true else {
            return .refuse(reason: "the built-in display is not active to begin with")
        }
        guard canChangeBrightness else {
            return .refuse(reason: "this Mac does not allow the panel's brightness to be set")
        }
        return .proceed(builtinID: builtinID)
    }

    /// Which brightness to write into the marker.
    ///
    /// Blackout runs *after* the lid has begun closing, and macOS is often
    /// part-way through its own fade by then, so reading the panel at that moment
    /// catches a level nobody chose. Measured across three cycles: 0.256 captured
    /// against a working ~0.56, 0.360 against ~0.84, and once 0.49997443 exactly
    /// right. A remembered value from while the lid was open is therefore
    /// preferred over a fresh reading whenever there is one.
    ///
    /// This only started to matter with `PanelMode.dim`. `.virtualDisplay` never
    /// reads the marker back on a healthy cycle — macOS restores its own
    /// brightness when the panel is re-enabled — so a low capture was harmless
    /// there. `.dim` writes the value back itself, which turns the same miss into
    /// a screen that returns at half the brightness it was left at.
    ///
    /// The remembered value is floor-gated by its caller, not here: a value below
    /// `panelVisibleFloor` is indistinguishable from a sample taken mid-fade, and
    /// the fresh reading is no worse than what this code did before.
    static func markerBrightness(lastOpenLid: Float?, currentReading: Float?) -> Float? {
        if let lastOpenLid, lastOpenLid.isFinite,
           lastOpenLid >= panelVisibleFloor, lastOpenLid <= 1 {
            return lastOpenLid
        }
        guard let currentReading, currentReading.isFinite,
              currentReading >= 0, currentReading <= 1 else { return nil }
        return currentReading
    }

    /// Reads the stored mode. Anything unrecognised — a typo written with
    /// `defaults write`, a value from a future version, an empty string — resolves
    /// to `PanelMode.default` rather than refusing: the setting says HOW to darken
    /// the panel, and failing to parse it is no reason to stop doing it.
    static func panelMode(in text: String?) -> PanelMode {
        guard let text else { return .default }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return PanelMode(rawValue: value) ?? .default
    }

    /// Whether the display carrying the session while the panel is held is
    /// still there. `carrier == nil` means no carrier exists at all — `.dim`
    /// never creates one.
    ///
    /// Both signals, because either can be the first to know: the display's own
    /// termination callback (`carrier.terminated`), and the window server's
    /// active list (`activeDisplayIDs`). Trusting only one accepted a blackout
    /// whose carrier had already left the list while the callback was still in
    /// flight, or never arrived at all.
    /// `displayAsleep` defaults to false so every existing caller and test keeps
    /// its meaning: "as far as we know the domain is awake". Only the live app,
    /// which observes `NSWorkspace.screensDidSleep/DidWake`, passes it.
    static func panelCarrierVerdict(
        carrier: (terminated: Bool, displayID: UInt32)?,
        activeDisplayIDs: [UInt32]?,
        displayAsleep: Bool = false
    ) -> CarrierState {
        guard let carrier else { return .gone }
        if carrier.terminated { return .gone }
        guard let activeDisplayIDs else { return .unknown }
        if activeDisplayIDs.contains(carrier.displayID) { return .alive }
        // Absent from the active list is TWO situations, and this line used to
        // collapse them into one. A carrier that vanished while the display
        // domain was awake is the emergency `sessionDisplayLost` exists for;
        // a carrier that vanished because the domain slept is the feature
        // succeeding — the panel is dark, which is the entire goal.
        //
        // Conflating them cost a night of churn on 2026-08-03/04: display sleep
        // switched the carrier off, the app read "nothing is showing anything",
        // restored the panel and re-armed, and the idle timer killed the
        // replacement ~26 s later, over and over until the churn ceiling.
        //
        // `terminated` is checked FIRST and still wins: a genuinely destroyed
        // display is gone whatever the domain is doing.
        return displayAsleep ? .asleep : .gone
    }

    /// Whether anything is still going to put the panel back on its own.
    ///
    /// False once the recovery watchdog is gone or the retry budget is spent, and
    /// the window needs to know: its "holding the panel down" note promised "it
    /// comes back on its own when the lid opens", which outranked — and therefore
    /// hid — the message saying the attempts had run out. A reassurance shown on
    /// top of the warning that contradicts it is worse than either alone.
    ///
    /// `.unknown` while we hold it means the panel's state cannot be read at all
    /// — and a `.dim` that lapsed on such a Mac can never be detected or
    /// re-applied, because an unreadable level is deliberately not treated as a
    /// lapse. Whatever that is, it is not automatic recovery, and saying "it
    /// comes back on its own when the lid opens" there is a promise nothing is
    /// keeping.
    static func panelRecoveryIsAutomaticDecision(
        restoreUnconfirmed: Bool,
        ownedByThisApp: Bool,
        presentation: PanelPresentation,
        watchdogRunning: Bool,
        attempts: Int,
        attemptCap: Int
    ) -> Bool {
        guard !restoreUnconfirmed else { return false }
        guard !(ownedByThisApp && presentation == .unknown) else { return false }
        return watchdogRunning && attempts < attemptCap
    }

    /// Whether to tear down the safety nets (watchdog, marker) after a failed
    /// blackout attempt, or leave them standing.
    ///
    /// An attempt made while `restoreUnconfirmed` is set inherits the marker
    /// and the watchdog from a restore nobody could confirm — they are not
    /// this attempt's to remove. Removing them was the fastest route to the
    /// worst state in this whole feature: a possibly-dark panel with no
    /// marker, no watchdog and `hasPanelToRestore` false, so neither
    /// reconcile, nor the termination handler, nor quit would ever try again.
    /// One more unreadable display list during a retry was enough to reach it.
    static func blackoutRollbackDecision(restoreUnconfirmed: Bool) -> Bool {
        !restoreUnconfirmed
    }

    /// Whether to write a fresh marker over whatever is already on disk.
    ///
    /// An inherited marker is NOT overwritten. When `restoreUnconfirmed` is
    /// set the panel may already be dark, and a fresh reading can fall back
    /// to a remembered or current value that is itself dark — rewriting here
    /// would replace a good recorded level with a dark one, and a later
    /// rollback would then faithfully preserve the corrupted restore point.
    /// The old file is the better answer precisely because it was written
    /// when the panel was known to be readable.
    ///
    /// Inherited only if it can be READ BACK (`savedReadable`) — `fileExists`
    /// was the wrong test: a corrupt or unparsable marker would be preserved
    /// in place of a fresh value that was available, and the restore would
    /// then fall back to a default instead of the level actually recorded.
    static func markerInheritDecision(restoreUnconfirmed: Bool, savedReadable: Bool) -> Bool {
        !(restoreUnconfirmed && savedReadable)
    }

    /// Whether the carrier is `.gone`, or has been `.unknown` for long enough
    /// that pretending otherwise is its own failure. Used where the question
    /// is "should this be undone", never where it is "may this proceed" —
    /// proceeding still demands a confirmed `.alive`.
    ///
    /// Only `.virtualDisplay` has a carrier at all. `.dim` never creates one,
    /// so a carrier verdict answers `.gone` for it by construction — without
    /// the `heldMode` gate below, the one-second lid watch that consults this
    /// fired a full system probe every single second for the whole length of
    /// a dim.
    ///
    /// The grace clock only counts while the CURRENT reading is still
    /// `.unknown` — switching on `carrierSnapshot` fresh each call, rather
    /// than trusting elapsed time alone, means a probe that recovered (and
    /// answered `.alive`) is never overruled by how long it had previously
    /// been unreadable, which would restore a working blackout for nothing.
    /// Whether a `dark -> lit` goal change should be held back for one refresh.
    ///
    /// **The problem it solves.** On the night of 2026-08-03/04 a working
    /// blackout was torn down and rebuilt eight times by single bad probe
    /// readings — five through `isFullyOn=false`, three through `hasLid=false` —
    /// each costing a lit panel under a closed lid, a fresh virtual display, and
    /// a reset of the churn budget. Every one of them was contradicted by the
    /// very next refresh. Two of the three fields involved had nothing to do
    /// with the lid, so a lid-only debounce would have caught almost none.
    ///
    /// **Why it keys on absence rather than on a timeout.** A probe that timed
    /// out and a probe that ran and found nothing arrive here identically —
    /// `Shell` collapses both to `(-1, "")` — and telling them apart would mean
    /// changing the shape every caller of `Shell` reads. It is not needed: what
    /// all eight had in common is that the goal flipped on something *missing*
    /// (no clamshell key, no evidence Lidless is on), never on a positive
    /// reading. So that is the discriminator.
    ///
    /// **A genuine lid opening is not delayed at all**, which is the point. It
    /// arrives as `hasLid=true, lidClosed=false, isFullyOn=true` — an assertion,
    /// not an absence — and passes through untouched, still restoring in the
    /// ~3 s the P0 runbook measures.
    ///
    /// **The safe direction is preserved, only postponed by one refresh.**
    /// `alreadyDeferred` makes this strictly one round: a second consecutive
    /// reading that says the same thing is believed. An unreadable world still
    /// resolves towards a lit screen — it just has to say so twice.
    static func panelGoalDeferralDecision(
        currentGoal: PanelGoal,
        proposedGoal: PanelGoal,
        watchdogLost: Bool,
        sessionDisplayLost: Bool,
        isFullyOn: Bool,
        hasLid: Bool,
        lidClosed: Bool,
        alreadyDeferred: Bool
    ) -> Bool {
        // Only ever delays giving the screen BACK. Going dark is never deferred:
        // that direction costs a lit panel behind a shut lid, which is the
        // inconvenience the feature exists to remove, not a way to lose a screen.
        guard currentGoal == .dark, proposedGoal == .lit else { return false }
        // The two safety conditions, and they are NEVER deferred. Both reach
        // `.lit` with the lid still shut, so the absence test below would have
        // caught them — postponing the one restore that exists because the way
        // back has gone, or because nothing is displaying anything, for the sake
        // of tidiness about probe noise. Excluded explicitly rather than left to
        // the reader of the rule.
        guard !watchdogLost, !sessionDisplayLost else { return false }
        guard !alreadyDeferred else { return false }
        // A positive reading of an open lid on a healthy Lidless is trusted
        // immediately — it is the normal path and must stay fast.
        if isFullyOn, hasLid, !lidClosed { return false }
        // Anything else that reaches `.lit` got there through an absence.
        return true
    }

    static func panelCarrierPresumedGoneDecision(
        heldMode: PanelMode?,
        carrierSnapshot: CarrierState,
        unknownSince: ContinuousClock.Instant?,
        now: ContinuousClock.Instant,
        unknownGraceSeconds: TimeInterval
    ) -> Bool {
        guard heldMode == .virtualDisplay else { return false }
        switch carrierSnapshot {
        case .gone: return true
        case .alive: return false
        // The display domain slept and took every display with it, this one
        // included. Nothing has been lost and nothing needs restoring — the
        // panel is dark, which is what the blackout was for.
        case .asleep: return false
        case .unknown:
            guard let unknownSince else { return false }
            return unknownSince.duration(to: now) >= .seconds(unknownGraceSeconds)
        }
    }

    /// Which way Panel blackout should currently be trying to go.
    ///
    /// `watchdogLost` and `sessionDisplayLost` fold straight into "not armed"
    /// rather than triggering a restore of their own: an out-of-band call
    /// would skip the attempt counter and the backoff, and a restore that
    /// keeps failing keeps ownership and the marker — so the next refresh
    /// would see the same condition and call again, immediately, forever.
    /// Folding them into the goal costs one term each and inherits the cap.
    ///
    /// This is this app's own knowledge of its own session, not a re-read of
    /// `pmset` — and `hasLid`/`lidClosed` both default to false when their
    /// probe fails, so an unreadable lid resolves to "put the panel back".
    /// Failing towards a visible screen is the only acceptable direction here.
    static func panelGoalDecision(
        watchdogLost: Bool,
        sessionDisplayLost: Bool,
        blackoutEnabled: Bool,
        isFullyOn: Bool,
        hasLid: Bool,
        lidClosed: Bool
    ) -> PanelGoal {
        let armed = !watchdogLost
            && !sessionDisplayLost
            && blackoutEnabled
            && isFullyOn
            && hasLid
            && lidClosed
        return armed ? .dark : .lit
    }

    /// Whether a failed/lapsed attempt may be forgiven — the retry budget and
    /// backoff reset — or must keep counting against the budget.
    ///
    /// Only forgiven once the marker is genuinely gone. An attempt that never
    /// finishes anything (the marker file is still there after whatever
    /// removal was attempted) is, for the attempt budget, indistinguishable
    /// from one that is still in progress — forgiving it anyway handed out a
    /// fresh set of attempts on every pass through a branch that never
    /// finishes.
    static func attemptForgivenessDecision(markerStillPresent: Bool) -> Bool {
        !markerStillPresent
    }

    /// Evaluated in the SAME order reconcile used to: the backoff wait comes
    /// BEFORE the cap check, so for up to `backoffCeiling` after attempts
    /// reach the cap this still answers `.wait`, not `.capReached` — the
    /// gave-up message/escalation fires only once the backoff window elapses,
    /// not the instant the cap is hit.
    static func panelAttemptDecision(
        now: ContinuousClock.Instant,
        nextAttempt: ContinuousClock.Instant,
        attempts: Int,
        attemptCap: Int,
        goal: PanelGoal,
        hasPanelToRestore: Bool,
        gaveUpReported: Bool,
        backoffStep: TimeInterval,
        backoffCeiling: TimeInterval
    ) -> PanelAttemptVerdict {
        guard now >= nextAttempt else { return .wait }
        guard attempts < attemptCap else {
            let showMessage = !gaveUpReported
            let shouldEscalate = showMessage && goal == .lit && hasPanelToRestore
            return .capReached(showMessage: showMessage, shouldEscalate: shouldEscalate)
        }
        // Backoff uses the POST-increment attempt count, matching the order
        // reconcile applied it in (`panelAttempts += 1` before computing the
        // delay) — using the pre-increment count would under-delay every
        // retry by one step.
        let nextCount = attempts + 1
        let delay = min(Double(nextCount) * backoffStep, backoffCeiling)
        return .proceed(nextAttempt: now.advanced(by: .seconds(delay)))
    }

    /// A floor on how often a virtual display may be built, independent of
    /// goals and attempt counters, and a ceiling on how many. Both from one
    /// persisted history, so neither can be reset by restarting — a carrier
    /// that keeps being confirmed gone produces restore → re-blackout →
    /// reset budget every ten seconds indefinitely; the rate floor alone
    /// permits that forever, and repeated display reconfiguration is the
    /// operation with the worst record in this project (five carriers in ten
    /// seconds once left the Mac with no displays at all).
    ///
    /// `prunedHistory` inside `ChurnResult` does NOT include an entry for
    /// `now` — the caller persists it unconditionally on every outcome, then
    /// additionally appends `now` and persists again only on `.proceed`,
    /// matching the two-write shape this replaced (write the pruned window
    /// first, before any guard can return early; write the appended history
    /// second, only once every guard has passed).
    ///
    /// `history` is expected already sorted (callers read it through a
    /// property that guarantees this) — `.max()` is used for the floor check
    /// anyway rather than `.last`, deliberately: this is the one guard in the
    /// file where trusting an ordering nobody enforces at the type level
    /// would have let a corrupt "newest, oldest" order through unnoticed.
    ///
    /// Both clocks — `now`/`churnWindow`/`reapplyFloor` (calendar) and
    /// `lastMonotonic`/`nowMonotonic` (monotonic) — have to agree before
    /// another display is built. The calendar side alone survives a restart
    /// (its history is persisted), which the monotonic side used not to: a
    /// force-quit and relaunch reset an in-memory-only version of it to
    /// `.distantPast`, and six quick restarts could build six carriers back
    /// to back.
    static func virtualDisplayChurnDecision(
        history: [Date],
        now: Date,
        lastMonotonic: ContinuousClock.Instant?,
        nowMonotonic: ContinuousClock.Instant,
        reapplyFloor: TimeInterval,
        churnWindow: TimeInterval,
        churnLimit: Int
    ) -> ChurnResult {
        let pruned = history.filter { now.timeIntervalSince($0) <= churnWindow }
        guard now.timeIntervalSince(pruned.max() ?? .distantPast) >= reapplyFloor else {
            return ChurnResult(prunedHistory: pruned, outcome: .rateLimited)
        }
        if let lastMonotonic, lastMonotonic.duration(to: nowMonotonic) < .seconds(reapplyFloor) {
            return ChurnResult(prunedHistory: pruned, outcome: .rateLimited)
        }
        guard pruned.count < churnLimit else {
            return ChurnResult(prunedHistory: pruned, outcome: .ceilingReached)
        }
        return ChurnResult(prunedHistory: pruned, outcome: .proceed)
    }
}
