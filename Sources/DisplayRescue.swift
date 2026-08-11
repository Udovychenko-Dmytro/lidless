// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Dmytro Udovychenko

import Foundation
import CoreGraphics

// lidless-display-rescue — the way out of Panel blackout, built before the trap.
//
// Runs blind by design: whoever needs this cannot see the screen. Every action it
// takes only ever makes a display APPEAR or a backlight come UP, so it is safe to
// run twice, safe to run when nothing is wrong, and safe to run with no idea what
// is wrong.
//
// It takes no display ID and trusts no list. On 2026-08-01 a burst of virtual
// display churn left this Mac with the built-in absent from CGGetActiveDisplayList,
// CGGetOnlineDisplayList AND CGSGetDisplayList at once, panel dark, unreachable
// locally and over remote desktop; recovery took the power button. A tool that
// needs to be told which display to fix is no use in that state.
//
//   lidless-display-rescue                     put everything back, once
//   lidless-display-rescue --explain           print what it would do, touch nothing
//   lidless-display-rescue --watch <pid> <hb>  wait for the owner to die or go quiet
//   lidless-display-rescue --dry-run           walk the same decision path as a bare
//                                               run, but call no mutating CoreGraphics
//                                               API — combine with --watch to make a
//                                               triggered sweep safe too. Tests only.

@main
struct DisplayRescue {
    /// `NSHomeDirectory()` resolves through the passwd entry and ignores $HOME for
    /// a plain binary (verified empirically: `HOME=/tmp/x` still returns the real
    /// home directory), so tests have no way to isolate the marker file the way
    /// the shell suite isolates `lidless.sh` by exporting `HOME` before sourcing
    /// it. This env var is the only seam, and it does nothing unless a test sets
    /// it — no real invocation of this binary ever has it in its environment.
    static var homeDirectory: String {
        ProcessInfo.processInfo.environment["LIDLESS_TEST_HOME"] ?? NSHomeDirectory()
    }

    /// The app's "a blackout is in progress" marker, which also carries a
    /// brightness to come back to. Same name in main.swift. That brightness is
    /// not reliably the level its owner was working at, and since 2026-08-02
    /// blackout does not change brightness at all — so this is a fallback for a
    /// panel found dark by other means, which is exactly this tool's job. See
    /// `SystemProbe.savedDisplayBrightness`.
    static let markerPath = homeDirectory + "/.lidless_display_prev"

    /// Highest legacy low ID the blind sweep tries. This is only a fallback:
    /// CGDirectDisplayID is opaque, and Intel has returned values in the tens of
    /// millions and above. `restoreDisplays()` always adds the currently attached
    /// built-in ID ahead of this range.
    static let highestDisplayID: UInt32 = 32

    static func log(_ text: String) {
        FileHandle.standardOutput.write(Data("\(text)\n".utf8))
    }

    static func lists() -> String {
        func show(_ ids: [UInt32]?) -> String { ids.map { "\($0)" } ?? "unreadable" }
        return "active=\(show(DisplayAPI.activeDisplayIDs()))"
            + " online=\(show(DisplayAPI.onlineDisplayIDs()))"
            + " windowServer=\(show(DisplayAPI.windowServerDisplayIDs()))"
    }

    /// The weakest claim that still means a human could see something: some display
    /// is active, and the one macOS calls main is among them.
    ///
    /// Good enough to decide whether to keep sweeping. **Not** good enough to
    /// decide the marker is finished with — see `builtinIsBack()`.
    static func somethingIsVisible() -> Bool {
        // Test-only escape hatch, and the mirror of the one in `builtinIsBack()`.
        // The r13 assertion needs BOTH halves of "something is visible but the
        // built-in is not confirmed back", and it forced only the second —
        // leaving the first to whatever the live machine happened to be doing.
        // Display sleep empties the active list completely (measured 2026-08-04,
        // the built-in goes too), so the assertion failed deterministically
        // whenever the suite ran while the display domain was asleep: 3 of 8
        // runs, every one of them with `active=[]`, and none otherwise.
        //
        // Not randomness, and not something the test could wait out. Unset in
        // every real invocation.
        if ProcessInfo.processInfo.environment["LIDLESS_TEST_FORCE_VISIBLE"] != nil {
            return true
        }
        guard let active = DisplayAPI.activeDisplayIDs(), !active.isEmpty else { return false }
        return active.contains(CGMainDisplayID())
    }

    /// The strong claim, and the only one allowed to delete the marker: the
    /// **built-in panel specifically** is back, present in the active list and at
    /// a level a human can read.
    ///
    /// `somethingIsVisible()` used to make that decision and it was wrong for the
    /// exact situation this tool exists for. A hung owner leaves its virtual
    /// display active *and* main, so the weak claim is satisfied by the very
    /// display standing in for the panel — and the marker went in the bin while
    /// the built-in was still off. In `.dim` that marker is the only record of the
    /// user's own brightness, so losing it means the panel never comes back to the
    /// level it was at.
    ///
    /// An unreadable brightness keeps the marker. That is the opposite of
    /// `SystemProbe.panelPresentation`'s rule for an unowned panel, deliberately:
    /// there, guessing wrong costs a red card on a healthy Mac, and here it costs
    /// the only way back. Wrong in the cheap direction each time.
    static func builtinIsBack() -> Bool {
        // Test-only escape hatch. There is no way to make this Mac's real
        // built-in read as "not back" without actually disabling it — and doing
        // that from a test is exactly the display-churn hazard this tool exists
        // to recover from (docs/ARCHITECTURE.md). Unset in every real invocation.
        if ProcessInfo.processInfo.environment["LIDLESS_TEST_FORCE_BUILTIN_GONE"] != nil {
            return false
        }
        guard let builtin = DisplayAPI.builtinDisplayID() else { return false }
        guard DisplayAPI.activeDisplayIDs()?.contains(builtin) == true else { return false }
        guard let level = DisplayAPI.brightness(of: builtin) else { return false }
        return level >= SystemProbe.panelVisibleFloor
    }

    static func savedBrightness() -> Float? {
        guard let text = try? String(contentsOfFile: markerPath, encoding: .utf8) else { return nil }
        return SystemProbe.savedDisplayBrightness(in: text)
    }

    static func savedVirtualDisplayID() -> UInt32? {
        guard let text = try? String(contentsOfFile: markerPath, encoding: .utf8),
              let id = SystemProbe.savedVirtualDisplayID(in: text) else { return nil }
        let live = Set(DisplayAPI.activeDisplayIDs() ?? [])
            .union(DisplayAPI.onlineDisplayIDs() ?? [])
            .union(DisplayAPI.windowServerDisplayIDs() ?? [])
        guard live.contains(id), DisplayAPI.isVirtualDisplay(id) else { return nil }
        return id
    }

    /// Puts displays back. Only ever enables.
    static func restoreDisplays() {
        // A permanent commit made while the recorded carrier is still alive adds
        // VirtDisplayN to WindowServer's persistent DisplaySets even if that same
        // transaction asks to disable it. On the next reboot macOS may select the
        // ghost set and remote capture freezes on its first frame. Do nothing
        // permanent until the owner exits and the virtual object actually leaves
        // the live lists; the watch process will retry when that happens.
        if let carrier = savedVirtualDisplayID() {
            log("live Lidless virtual display=\(carrier); permanent restore deferred until it disappears")
            return
        }

        // Cheapest first, and public API at that. Returns Void, so whether it
        // helped can only be established by re-reading afterwards.
        DisplayAPI.restorePermanentConfiguration()
        Thread.sleep(forTimeInterval: 1.5)
        if somethingIsVisible() {
            log("after CGRestorePermanentDisplayConfiguration: \(lists())")
        }

        // kCGConfigurePermanently, not ForAppOnly. This process exits immediately,
        // and an app-scoped enable would be undone the moment it does. Reaching
        // this point proves the marker's virtual object is no longer live, which
        // is the precondition for a permanent commit not to persist VirtDisplayN.
        let attachedBuiltin = DisplayAPI.builtinDisplayID()
        let candidates = SystemProbe.displayRescueCandidateIDs(
            builtinID: attachedBuiltin,
            legacyUpperBound: highestDisplayID
        )
        log("sweep candidates=\(candidates)")
        var accepted: [UInt32] = []
        for id in candidates {
            let enabled = DisplayAPI.setDisplayEnabled(id, true, option: .permanently)
            if enabled { accepted.append(id) }
            // The opaque attached ID is the useful operation on Intel. Once that
            // configuration has landed, another 32 speculative commits only add
            // churn to the WindowServer we are trying to stabilise.
            if id == attachedBuiltin, enabled {
                Thread.sleep(forTimeInterval: 2.0)
                if DisplayAPI.activeDisplayIDs()?.contains(id) == true {
                    log("attached built-in is active; legacy sweep skipped")
                    log("sweep accepted=\(accepted)")
                    return
                }
            }
        }
        log("sweep accepted=\(accepted)")
        Thread.sleep(forTimeInterval: 2.0)
    }

    /// Brings the light back — but only where it is actually out.
    ///
    /// Re-enabling a display left at minimum brightness hands back a working Mac
    /// showing a black screen, which reads as broken hardware. Equally, measured
    /// 2026-08-01, macOS restores the user's own brightness within seconds of an
    /// app-scoped display config reverting: a version of this that always wrote a
    /// value of its own replaced a correct 0.0625 with a floor, and that is a
    /// second bug wearing a safety net's clothes.
    static func restoreBrightness() {
        let saved = savedBrightness()
        for id in Set(DisplayAPI.activeDisplayIDs() ?? [])
            .union(DisplayAPI.onlineDisplayIDs() ?? [])
            .union(DisplayAPI.windowServerDisplayIDs() ?? []) {
            guard DisplayAPI.canChangeBrightness(id) else {
                log("brightness id=\(id) cannot be driven — skipped")
                continue
            }
            let current = DisplayAPI.brightness(of: id)
            switch SystemProbe.panelBrightnessDecision(savedValue: saved, currentValue: current) {
            case .leaveAlone:
                log("brightness id=\(id) already \(current.map { "\($0)" } ?? "?") — left alone")
            case .restore(let value):
                DisplayAPI.setBrightness(value, on: id)
                log("brightness id=\(id) -> \(value)")
            }
        }
    }

    /// `dryRun` walks the exact same decision path — the same reads, the same
    /// three-way branch, the same return-value rule below — and calls neither
    /// mutating action nor `removeItem`. Its ONLY behavioural difference from a
    /// bare run is that skip, plus one stable `decision:` line per branch so a
    /// test can assert on the decision without ever depending on a side effect.
    /// The default (`false`) path is byte-for-byte what shipped before this
    /// parameter existed — the whole point is to test the binary that ships, not
    /// a variant of it.
    @discardableResult
    static func rescueOnce(dryRun: Bool = false) -> Bool {
        // Read before anything is restored or removed: it is what tells this tool
        // whether there is supposed to BE a built-in panel.
        let markerPresent = FileManager.default.fileExists(atPath: markerPath)
        log("before: \(lists()) marker=\(markerPresent)")
        if case .unavailable(let reason) = DisplayAPI.support {
            // Not a reason to stop. Some of what follows is public API and may
            // still work, and this tool only ever makes things visible.
            log("warning: \(reason) — continuing anyway")
        }
        if dryRun {
            log("dry-run: skipping restoreDisplays() and restoreBrightness()")
        } else {
            restoreDisplays()
            restoreBrightness()
        }

        let visible = somethingIsVisible()
        let builtinBack = builtinIsBack()
        log("after: \(lists()) visible=\(visible) builtinBack=\(builtinBack)")
        if builtinBack {
            if dryRun {
                log("decision: would-remove-marker")
            } else if FileManager.default.fileExists(atPath: markerPath) {
                // Removed only on confirmed success, and only here: this runs when the
                // owner is dead or hung, so there is no live state to tread on.
                // Keyed to the built-in, not to `visible` — a virtual display standing
                // in for the panel satisfies `visible` while the panel is still off.
                do {
                    try FileManager.default.removeItem(atPath: markerPath)
                    log("marker removed")
                } catch {
                    // Logged, not swallowed. `try?` here printed "marker removed"
                    // over a file that was still there, and the app then read that
                    // as a finished recovery and handed itself a fresh retry
                    // budget on every pass.
                    log("marker could NOT be removed: \(error.localizedDescription)")
                }
            }
        } else if visible {
            log("something is visible, but the built-in panel is not confirmed back")
            if dryRun {
                log("decision: would-keep-marker")
            } else {
                log("marker kept so the next attempt still knows what to restore")
            }
        } else {
            log("still blind. From a shell on another machine:")
            log("  sudo killall -HUP WindowServer   # re-enumerates displays; logs you out")
            if dryRun {
                log("decision: would-report-failure")
            } else {
                log("marker kept so the next attempt still knows what to restore")
            }
        }
        // The exit status follows the BUILT-IN, because `lidless.sh
        // rescue-display` hands this straight back to a human and the app accepts
        // nothing weaker either. Exiting 0 while only a virtual display is visible
        // said "recovered" about the very display that was standing in for the
        // failure.
        //
        // `builtinDisplayID() == nil` is NOT "this Mac has no panel". It is also
        // the disaster this tool was written for — on 2026-08-01 the built-in went
        // missing from all three lists at once. The marker settles it: if one is on
        // disk a blackout was in progress, so a built-in exists and its absence is
        // the failure, not the answer. Only with no marker at all is "no built-in"
        // allowed to mean a desktop, and then the weak claim is all there is.
        if builtinBack { return true }
        if DisplayAPI.builtinDisplayID() == nil, !markerPresent { return visible }
        return false
    }

    /// Outlives a HUNG owner, which `kill -0` alone cannot detect: a process that
    /// is still alive but has stopped making progress leaves the panel dark with
    /// nobody to put it back. A stale heartbeat is the only evidence of that from
    /// outside. Both thresholds below are chosen, not measured — see docs/ARCHITECTURE.md
    ///
    /// **25, not 20, since 2026-08-06.** It used to be exactly
    /// `Shell.defaultTimeout` (20 s, `SystemProbe.swift`), which meant a single
    /// shell call running to its full timeout — ~21 s in practice, because
    /// `Shell.collect` waits another `limit + 1 s` after SIGTERM before SIGKILL —
    /// consumed the entire budget, with `graceBeforeRescue` on top of it as the
    /// only slack. The real fix is that the heartbeat no longer runs on the
    /// blockable main thread (`Lidless.startPanelHeartbeat`); this is the
    /// mitigation beside it, so the two numbers are no longer equal and a fully
    /// stalled process still gets more than that ~21 s tail before its blackout
    /// is swept. It is deliberately not much larger: every second here is a
    /// second a genuinely hung owner leaves the screen dark. Its cross-file twins
    /// are `Shell.defaultTimeout` and `Lidless.panelHeartbeatInterval` (5 s —
    /// four touches per window).
    ///
    /// The value itself lives in `SystemProbe` because the app needs it too — it
    /// asks the same question at launch, about a heartbeat that may belong to a
    /// second instance (`SystemProbe.strandedHeartbeatDecision`). One constant,
    /// two binaries; this name is kept because the docs and NOTES cite it.
    static let heartbeatStaleAfter: TimeInterval = SystemProbe.panelHeartbeatStaleAfter
    static let graceBeforeRescue: TimeInterval = 3

    static func watch(ownerPID: Int32, heartbeatPath: String, dryRun: Bool = false) -> Never {
        // The readiness handshake, and the first thing this does. The app waits
        // for this file before it touches the panel: `Process.run()` returning —
        // and even the process still existing a moment later — proves only that
        // something was spawned, not that it reached THIS loop with arguments it
        // understood. A wrong-architecture or argument-refusing binary never gets
        // here, and the app must find that out while the screen is still lit.
        FileManager.default.createFile(
            atPath: heartbeatPath + SystemProbe.displayWatchdogReadySuffix,
            contents: nil
        )
        log("watching owner=\(ownerPID) heartbeat=\(heartbeatPath)")
        while true {
            Thread.sleep(forTimeInterval: 2)
            let ownerAlive = kill(ownerPID, 0) == 0
            // A file's mtime is calendar time and there is no monotonic version
            // of it, so this comparison cannot be made clock-proof — but it can be
            // made to fail in the right direction. A negative age means the clock
            // moved backwards, which used to read as "very fresh" and suppressed
            // this watchdog indefinitely. Treated as stale instead: firing costs a
            // sweep that only ever makes displays appear, and not firing costs the
            // screen.
            let age: TimeInterval
            if let attributes = try? FileManager.default.attributesOfItem(atPath: heartbeatPath),
               let modified = attributes[.modificationDate] as? Date {
                let measured = Date().timeIntervalSince(modified)
                age = measured < 0 ? .infinity : measured
            } else {
                age = .infinity
            }
            guard !ownerAlive || age >= heartbeatStaleAfter else { continue }
            log("triggered: ownerAlive=\(ownerAlive) heartbeatAge=\(age)")
            // Give the app-scoped configuration its chance to revert on its own
            // first. When it does, the sweep below simply finds nothing to do,
            // which is the intended outcome rather than a wasted run.
            Thread.sleep(forTimeInterval: graceBeforeRescue)

            // Run the sweep in a CHILD, supervised, rather than in this process.
            // `rescueOnce()` makes up to 32 `CGCompleteDisplayConfiguration` calls
            // with nothing above them; one that wedges took the whole watchdog
            // with it, and since this then `exit`ed there was no second attempt
            // ever. A child can be killed and tried again.
            //
            // `Shell.run` is the bounded one now (SystemProbe.swift), and this
            // binary compiles it in.
            var attempts = 0
            while attempts < sweepAttempts {
                attempts += 1
                // `Bundle.main.executableURL`, not `argv[0]`. The latter is just
                // the string this process was launched with, so moving or renaming
                // the bundle while the watchdog runs left every sweep failing to
                // exec — and the one thing that could still recover the screen
                // then gave up because its own path had gone stale.
                let selfPath: String = Bundle.main.executableURL?.path
                    ?? CommandLine.arguments[0]
                // A triggered watch spawns this same binary again, so a watch
                // started with --dry-run must pass it on — otherwise the one
                // path this flag exists to make safe would be the one place it
                // silently stopped applying.
                let result = Shell.run(
                    Shell.Command(selfPath, dryRun ? ["--dry-run"] : []),
                    timeout: sweepTimeout
                )
                log("sweep attempt \(attempts) status=\(result.status)")
                if builtinIsBack() { exit(0) }
                if attempts < sweepAttempts { Thread.sleep(forTimeInterval: graceBeforeRescue) }
            }
            // Back to watching rather than `exit(1)`. A WindowServer fault can be
            // temporary, and this process is the only thing left that can act on
            // it once the owner is gone — resigning after three tries made the
            // last line of defence a three-shot one. Sweeps only ever make
            // displays appear, so retrying slowly costs nothing but a process.
            log("no luck after \(sweepAttempts) supervised sweeps; waiting \(Int(retryCoolOff))s before watching again")
            Thread.sleep(forTimeInterval: retryCoolOff)
        }
    }

    /// Supervised sweeps before the watchdog gives up, and how long each may take.
    /// The sweep sleeps 3.5 s of its own and then makes up to 32 display calls.
    /// Chosen, not measured (docs/ARCHITECTURE.md).
    static let sweepAttempts = 3
    static let sweepTimeout: TimeInterval = 45
    /// Gap before a fresh round of sweeps when three in a row achieved nothing.
    static let retryCoolOff: TimeInterval = 60

    static func main() {
        // Accepted in any position, and stripped before every other check below
        // so their positional indexing (arguments[1], arguments[2], ...) is
        // exactly what it was before this flag existed.
        var arguments = CommandLine.arguments
        let dryRun = arguments.contains("--dry-run")
        arguments.removeAll { $0 == "--dry-run" }

        if arguments.count >= 2 && arguments[1] == "--explain" {
            let saved = savedBrightness()
            let builtin = DisplayAPI.builtinDisplayID()
            let current = builtin.flatMap { DisplayAPI.brightness(of: $0) }
            log("support=\(DisplayAPI.support)")
            log("displays: \(lists()) builtin=\(builtin.map { "\($0)" } ?? "none")")
            log("marker=\(saved.map { "\($0)" } ?? "absent or invalid") current=\(current.map { "\($0)" } ?? "unreadable")")
            log("would: \(SystemProbe.panelBrightnessDecision(savedValue: saved, currentValue: current))")
            exit(0)
        }

        if arguments.count >= 4 && arguments[1] == "--watch" {
            guard let pid = Int32(arguments[2]) else {
                log("usage: lidless-display-rescue --watch <pid> <heartbeat-file>")
                exit(64)
            }
            watch(ownerPID: pid, heartbeatPath: arguments[3], dryRun: dryRun)
        }

        exit(rescueOnce(dryRun: dryRun) ? 0 : 1)
    }
}
