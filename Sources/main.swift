// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Dmytro Udovychenko

import SwiftUI
import Foundation
import CoreGraphics
import IOKit.pwr_mgt

// Shell, SystemState and SystemProbe live in SystemProbe.swift so the parsing
// can be compiled into tests/swift without dragging in the UI. DisplayAPI and
// VirtualDisplay live in VirtualDisplay.swift for the opposite reason: they are
// in-process private CoreGraphics calls that the test binaries must never link.

// MARK: - Settings keys

enum Keys {
    static let keepAwakeOnBattery = "keepAwakeOnBattery"
    static let lowPowerWhileActive = "lowPowerWhileActive"
    static let relaxScreenLock = "relaxScreenLock"
    static let stopAllCaffeinate = "stopAllCaffeinate"
    static let screenLockDelay = "screenLockDelay"
    static let shutdownAfterHours = "automaticShutdownAfterHoursV1"
    static let shutdownBelowBatteryPercent = "automaticShutdownBelowBatteryPercentV1"
    static let disableOnQuit = "disableOnQuit"
    /// `V1` for the same reason as the two shutdown keys: the semantics are
    /// destructive enough that a future change of meaning must not silently
    /// inherit a value someone set for the old one. Turning this on can take the
    /// only screen a person has away.
    static let blackoutBuiltinDisplay = "blackoutBuiltinDisplayV1"
    /// How the panel is darkened once `blackoutBuiltinDisplay` is on: the raw
    /// value of a `PanelMode`. `V1` for the same reason as the key above — both
    /// modes change what a person can see, so a future redefinition must not
    /// inherit a value chosen for the old meaning. Absent or unrecognised reads
    /// as `PanelMode.default`, so the feature never fails closed on a typo.
    static let panelMode = "panelModeV1"
    /// App-internal, unlike the keys above: `lidless.sh` neither reads nor writes
    /// it, and nothing about it is a shared setting.
    static let virtualDisplayChurn = "virtualDisplayChurnV1"
    static let legacyEnabledAt = "enabledAt"
}

// MARK: - Controller

/// One bit, shared between the thread making an SMC call and the main actor
/// deciding whether that call is stuck. Written once by the sampling thread the
/// moment `SMCConnection.read()` returns, read by `Lidless.sampleSensors()` on
/// the next tick.
///
/// A whole reference type for one Bool, rather than reusing the actor-isolated
/// flags next to it, because it must be readable from a main actor that has not
/// yet run the completion — which is precisely the state those flags cannot
/// describe. `NSLock` keeps the write visible to the reading thread; the value
/// only ever goes false to true, so no reader can see it move backwards.
final class SensorSampleProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var returned = false

    /// The sampling task got a thread and is about to call into the SMC.
    /// Before this, nothing has been asked of the kernel at all — a sample that
    /// has not started cannot be stuck in a call it never made.
    func markStarted() {
        lock.lock()
        started = true
        lock.unlock()
    }

    func markReturned() {
        lock.lock()
        returned = true
        lock.unlock()
    }

    var hasStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    var hasReturned: Bool {
        lock.lock()
        defer { lock.unlock() }
        return returned
    }
}

@MainActor
final class Lidless: ObservableObject {
    /// One instance, reachable from both the SwiftUI scene and the app delegate.
    /// The delegate needs it during termination, which is too late to be handed
    /// it through the view hierarchy.
    static let shared = Lidless()

    @Published var state = SystemState()
    @Published var busy = false
    /// The single note slot. 56 sites assign to it and, until 2026-08-06, one
    /// path cleared it — `beginAction(clearMessage: true)`, called from exactly
    /// one place — so a line could sit there for the rest of the session,
    /// outranking the unreadable lid and the battery-drain warning in
    /// `notePanel`'s priority chain. It is dismissible now.
    @Published var message: String? {
        didSet {
            // Any plain assignment is a report about something that already
            // happened. `setProgressMessage` re-raises this immediately after
            // assigning, which is the only way it becomes true.
            messageIsProgress = false
        }
    }

    /// Whether the current note describes work still in flight rather than
    /// something that failed. The comment in `notePanel` used to assert "a
    /// message is never good news"; two sites contradicted it, so the app drew
    /// its own happy path as an amber warning.
    @Published private(set) var messageIsProgress = false

    /// False until the first full probe has landed. Every reading in
    /// `SystemState` defaults to a confident-looking negative —
    /// `lidStateReadable` and `privilegedSupportInstalled` are both `false`
    /// initially — and `refresh()` is async, so the app opened on an amber
    /// UNKNOWN verdict, an amber "Not installed" permission card and an empty
    /// sensor strip: three failures, none of them true, before anything had been
    /// read at all.
    @Published private(set) var hasCompletedFirstRead = false
    @Published private(set) var automaticShutdownPending = false
    @Published private(set) var externalAutomaticShutdownPending = false
    /// When the current session started, or nil if there is no session. Read from
    /// `enabledAtFile` on every refresh rather than set at Enable time, so a
    /// session started by `lidless.sh` — or one that outlived a previous run of
    /// this app — is reported just as accurately as one this app started.
    @Published private(set) var sessionStartedAt: Date?
    /// The SMC strip's readings. Deliberately not part of `state`: nothing here
    /// comes from `SystemProbe.read`, and nothing here may ever be allowed to
    /// delay it. See `Sources/SMCSensors.swift`'s header and
    /// `docs/SMC_SENSORS.md`.
    @Published private(set) var sensors = SensorReadings()
    /// When a pending automatic shutdown will fire. Only set for a shutdown this
    /// app is counting down; an `externalAutomaticShutdownPending` one belongs to
    /// the LaunchAgent, which does not publish its deadline.
    @Published private(set) var automaticShutdownDeadline: Date?
    /// What the built-in panel is doing. Re-read on every refresh from the live
    /// display lists rather than tracked as a flag: a `kCGConfigureForAppOnly`
    /// disable was measured coming undone by itself while the owner was still
    /// alive, and a version that trusted its own bookkeeping simply stopped
    /// noticing. See docs/ARCHITECTURE.md
    @Published private(set) var panelPresentation: PanelPresentation = .unknown

    private let pidFile = NSHomeDirectory() + "/.lidless_caffeinate_pid"
    private let screenLockFile = NSHomeDirectory() + "/.lidless_screenlock_prev"
    private let lowPowerFile = NSHomeDirectory() + "/.lidless_lowpower_prev"
    /// Unix epoch seconds. A file rather than a defaults key, because the
    /// LaunchAgent watchdog reads it from a plain shell script — and it is the
    /// watchdog, not this app, that has to enforce the auto-off limits once the
    /// app has been quit.
    private let enabledAtFile = NSHomeDirectory() + "/.lidless_enabled_at"
    private let shutdownPendingFile = NSHomeDirectory() + "/.lidless_shutdown_pending"
    private let shutdownCancelFile = NSHomeDirectory() + "/.lidless_shutdown_cancel"
    /// The first line is a brightness, matching older builds. Virtual-display
    /// mode adds the carrier's current opaque ID on a second line so the rescue
    /// tool can exclude that exact display from a permanent topology commit. The
    /// ID is never trusted across reboot without confirming it is live and still
    /// virtual. Owner liveness is a separate file, below. The path is also
    /// hardcoded in `DisplayRescue.markerPath`, which has to find it with this
    /// app dead.
    ///
    /// Its primary job is to EXIST: the file is how a restarted app or
    /// `lidless-display-rescue` learns a blackout is in progress at all. The
    /// brightness inside it is secondary, is not reliably the level its owner was
    /// working at, and since 2026-08-02 is not read on any normal path — blackout
    /// no longer changes brightness, so there is nothing to put back. See
    /// `SystemProbe.savedDisplayBrightness` for the measurements.
    private let displayFile = NSHomeDirectory() + "/.lidless_display_prev"
    /// Touched every few seconds while the panel is held down. Its age is the
    /// only evidence from outside that this app is HUNG rather than dead —
    /// `kill -0` cannot tell those apart, and a hung owner leaves the panel dark
    /// with nobody to put it back.
    private let displayHeartbeatFile = NSHomeDirectory() + "/.lidless_display_heartbeat"
    /// Interprocess lock so a concurrent CLI + app enable/disable cannot race
    /// on stale state and start two caffeinate processes. Not removed on
    /// disable — see lidless.sh's matching LOCK_FILE comment.
    private let lockFile = NSHomeDirectory() + "/.lidless_lock"

    private var heartbeat: Timer?
    private var refreshInFlight = false
    private var refreshRequested = false
    private var stateRevision: UInt64 = 0
    private var lastAutomaticShutdownAttempt: Date?
    private var automaticShutdownGraceTask: Task<Void, Never>?
    private var lastPrivilegeProbeAt: Date?

    /// The sensor sampler's own state, kept entirely separate from
    /// `refreshInFlight`/`refreshRequested` above. Nothing in `sampleSensors()`
    /// reads or writes those, and nothing here is read by `refresh()`, the
    /// panel heartbeat, or the blackout reconcile — a wedged SMC call must be
    /// able to leak one background task and nothing else.
    private var sensorTimer: Timer?
    private var sensorSampleInFlight = false
    private var sensorSampleStartedAt: Date?
    /// The in-flight sample's own progress flag, flipped on the sampling thread
    /// the instant `SMCConnection.read()` returns. See `sampleSensors()` for
    /// why the elapsed time alone cannot be trusted.
    private var sensorSampleProgress: SensorSampleProgress?
    /// One-way for the life of the process. See `sampleSensors()`.
    private var sensorsAbandoned = false
    /// How many UI surfaces (window, popover) are currently on screen. Decides
    /// which of the two cadences the timer runs at.
    private var sensorSurfacesVisible = 0

    /// Non-nil for exactly as long as this app is holding the built-in panel
    /// down. The window server drops the virtual display when this process exits,
    /// so its lifetime *is* the blackout's lifetime — and it is never released
    /// before the built-in is confirmed back, or there would be a window with no
    /// display at all.
    ///
    /// That teardown is NOT what makes a crash survivable; the disable of the
    /// built-in outlives the process (see `DisplayAPI.setDisplayEnabled`). The
    /// recovery watchdog is what makes a crash survivable, which is why blackout
    /// refuses to start without it.
    private var panelVirtualDisplay: VirtualDisplay?
    /// Which mode is actually in force, recorded when the blackout takes and
    /// cleared with `panelBuiltinID`.
    ///
    /// Not derived from `panelVirtualDisplay != nil`, which was a bug with teeth:
    /// `panelVirtualDisplayVanished` clears that reference FIRST and then defers
    /// the restore when an operation is in flight, so a `.virtualDisplay` blackout
    /// spends that window looking exactly like a `.dim` one. Reconcile then read
    /// the brightness of a built-in it had disabled, got nothing, concluded
    /// nothing had lapsed, and left the panel off with the display that was
    /// standing in for it already gone. Not derived from the picker either — that
    /// is a setting the user can change mid-blackout, and it answers "what would
    /// happen next time", not "what is happening now".
    private var panelHeldMode: PanelMode?
    /// A restore that put the display back but could not prove the panel is
    /// readable. Ownership is released — nothing is being held, and claiming
    /// otherwise blocked the next blackout forever — while the marker, the
    /// heartbeat and the watchdog all stay, so a crash from here still recovers.
    ///
    /// This replaces an earlier "keep ownership so the watchdog survives", which
    /// treated the two as one choice. They are not: the watchdog watches a pid and
    /// a heartbeat file, and has never needed `panelBuiltinID` to do it.
    private var panelRestoreUnconfirmed = false

    /// Whether a `dark -> lit` goal change was already held back once. Reset
    /// the moment a change is acted on, or the moment the world agrees with the
    /// goal we already hold — so this can only ever postpone by a single
    /// refresh, never accumulate into a blackout that refuses to end.
    /// Holds display sleep off for as long as a `.virtualDisplay` blackout is
    /// held — and only then.
    ///
    /// **This is D1, withdrawn on 2026-08-04 and reinstated the same day on a
    /// corrected premise.** It was withdrawn after D0 showed the carrier only
    /// ever died while the display domain slept, and that an idle Mac darkens
    /// its own panel anyway: holding the display awake to protect a carrier
    /// whose job was already being done for free looked like burning power for
    /// nothing.
    ///
    /// That reasoning assumed a requirement rather than asking about one. The
    /// requirement is that in this mode the virtual display is **always on** —
    /// it is what the session lives on, and the physical panel is off precisely
    /// so that it can be. A carrier that sleeps is not a saving, it is the
    /// feature not working: on 2026-08-04 20:24 the domain slept, the carrier
    /// went with it, and a remote session connecting four minutes later found
    /// nothing displaying anything at all.
    ///
    /// The power argument survives intact, which is why this is affordable: the
    /// backlight is what costs, and the backlight belongs to the built-in, which
    /// stays disabled throughout. What is being kept awake is a framebuffer with
    /// no panel behind it.
    ///
    /// `.dim` deliberately does NOT take this. There the real panel is the one
    /// showing, and letting it sleep is exactly right.
    private var displaySleepAssertion: IOPMAssertionID?

    private var panelGoalDeferred = false

    /// Whether the display domain is asleep, from
    /// `NSWorkspace.screensDidSleep/DidWake`. Read by `panelCarrierState` so a
    /// carrier switched off by display sleep is told apart from one that was
    /// lost — see `CarrierState.asleep`.
    ///
    /// Starts false, which is the safe direction: an app launched while the
    /// screens are already asleep treats an absent carrier as gone and restores,
    /// costing a lit panel rather than a dark one. The first wake corrects it.
    private var displayDomainAsleep = false

    /// What the lid watch recorded last. That timer fires every second, so a
    /// line per tick would be 3600 identical entries an hour — enough to age the
    /// unified log's buffer out from under the very incident it is there to
    /// explain. Recording only the changes keeps the whole blackout visible
    /// while costing a handful of lines.
    private var lastLidWatchNote: String = ""

    /// Intel's WindowServer removes a closed built-in panel so completely that a
    /// synchronous enable request can stop returning. There is no useful panel
    /// to show behind a closed lid anyway, so keep the virtual carrier and its
    /// watchdog alive and finish the restore after the lid opens. Apple Silicon
    /// has been verified to restore while closed and keeps its existing path.
    private var shouldDeferPanelRestoreUntilLidOpen: Bool {
        #if arch(x86_64)
        return SystemProbe.panelRestoreSchedule(
            isIntel: true,
            usesVirtualCarrier: panelHeldMode == .virtualDisplay,
            hasLid: state.hasLid,
            lidClosed: state.lidClosed
        ) == .waitForLidOpen
        #else
        return false
        #endif
    }
    /// When a virtual display was last created. The floor below is measured from
    /// here and NOT from `panelAttempts`, which cannot bound this: the attempt
    /// counter resets on every success and on every change of goal, so a
    /// restore/re-blackout oscillation resets its own budget forever.
    /// Creation times inside `virtualDisplayChurnWindow`, oldest first. The floor
    /// above bounds the RATE; this bounds the COUNT, and they are not the same
    /// guard: a display that keeps being confirmed gone produces a restore, a
    /// re-blackout, and a reset attempt budget every ten seconds, forever.
    ///
    /// Persisted, because the state it guards against is the window server's and
    /// not this app's: it survives a restart, and "stopped trying" is exactly the
    /// message that makes somebody relaunch. Kept in `UserDefaults` rather than a
    /// new state file — nothing outside this app reads it, and the documented
    /// state-file set (docs/ARCHITECTURE.md) is a contract shared with `lidless.sh`.
    private var recentVirtualDisplays: [Date] {
        get {
            let now = Date().timeIntervalSince1970
            // Read defensively and sanitised. A single wrong-typed element used to
            // turn the whole array into an empty one — silently removing the
            // ceiling — and a NaN, an infinity or a future timestamp could never
            // age out of the window, silently making it permanent. Both directions
            // of a corrupt value disable the guard that exists for the operation
            // with the worst record in this project.
            let raw = UserDefaults.standard.array(forKey: Keys.virtualDisplayChurn) ?? []
            return raw
                .compactMap { $0 as? Double }
                .filter { $0.isFinite && $0 > 0 }
                // Clamped, not dropped. Filtering future stamps out meant a clock
                // that jumped forward and back erased the very history that was
                // holding the rate limit down; treating them as "just now" errs
                // towards keeping the brake on.
                .map { Date(timeIntervalSince1970: Swift.min($0, now)) }
                .sorted()
        }
        set {
            UserDefaults.standard.set(
                newValue.map { $0.timeIntervalSince1970 },
                forKey: Keys.virtualDisplayChurn
            )
        }
    }
    /// How long `panelCarrierState` has been `.unknown` without a break, or nil
    /// when it is not. A single unreadable display list must not tear a working
    /// blackout down; one that never clears must not be accepted forever either,
    /// because the heartbeat stays fresh and the external watchdog therefore never
    /// fires. This is what separates the two.
    private var panelCarrierUnknownSince: ContinuousClock.Instant?
    /// The carrier state as of the last `notePanelCarrierState()`. Recorded, not
    /// re-derived: the clock and the presumed-gone test each read the active
    /// display list on their own, so a list flickering between readable and not
    /// could clear the clock on one read and be judged on the other in the same
    /// tick. Same rule as `panelHeldMode` — one snapshot, one decision.
    private var panelCarrierSnapshot: CarrierState = .gone
    /// Monotonic companion to the persisted churn history. That history has to be
    /// calendar time — a monotonic instant means nothing after a restart — so a
    /// clock jumped forward by more than the window ages real entries out and
    /// lifts both brakes at once. This one cannot be jumped, and covers the rate
    /// floor for as long as the process lives, which is when a burst is possible.
    private var lastVirtualDisplayMonotonic: ContinuousClock.Instant?
    private var panelBuiltinID: UInt32?
    /// The last brightness seen with the lid OPEN and this app holding nothing —
    /// what goes into the marker, in preference to a reading taken once blackout
    /// is already under way. Refreshed by `readPanelPresentation` on every probe,
    /// so it is at most one refresh interval old: 5 s with the window open, 60 s
    /// without. Deliberately NOT persisted; a value from a previous launch says
    /// nothing about what the panel is doing now.
    private var panelOpenLidBrightness: Float?
    private var panelHeartbeat: DispatchSourceTimer?
    /// The heartbeat runs here, not on the main run loop. `.userInitiated`
    /// rather than `.utility`: a queue the system is free to defer is a queue
    /// that can miss the deadline this file exists to beat.
    private static let panelHeartbeatQueue = DispatchQueue(
        label: "io.github.lidless.panel-heartbeat", qos: .userInitiated
    )
    private var panelLidWatch: Timer?
    /// Guards against a second `ioreg` while the first is still running. At one
    /// tick a second a probe that hangs would otherwise spawn a process per second
    /// with nothing bounding the pile.
    private var panelLidProbeInFlight = false
    private var panelWatchdog: Process?
    private var panelGoal: PanelGoal = .lit
    private var panelAttempts = 0
    /// Monotonic, like every other deadline on this path: a clock pushed
    /// backwards after a fifteen-second backoff postponed the next attempt by the
    /// size of the jump.
    private var nextPanelAttempt: ContinuousClock.Instant = .now
    private var panelGaveUpReported = false
    private var panelObservers: [NSObjectProtocol] = []
    /// AppKit may ask again while a `.terminateLater` reply is outstanding. A
    /// second cleanup task would race the first one for the panel and state files.
    private var terminationInFlight = false

    /// How often state is re-read with no window and no popover on screen. The
    /// last bare literal in this block, while ~30 neighbours were named and
    /// justified. Chosen, not measured (docs/ARCHITECTURE.md): with nothing visible the only
    /// jobs left are noticing an orphaned lid setting and evaluating the
    /// automatic-shutdown limits, and the limits are already only as prompt as
    /// the LaunchAgent's own 300 s tick.
    private static let backgroundRefreshInterval: TimeInterval = 60

    private static let automaticShutdownRetryInterval: TimeInterval = 5 * 60
    private static let automaticShutdownGraceNanoseconds: UInt64 = 60_000_000_000
    /// How long an expired countdown waits when a mutating operation holds
    /// `busy`, before asking again. Chosen, not measured (docs/ARCHITECTURE.md): short
    /// enough that a shutdown the user was warned about still happens promptly,
    /// long enough not to spin against an Enable that is waiting on a password
    /// dialog. Prevents the failure where the countdown simply vanished —
    /// `automaticShutdown` returns on `busy` without a word.
    private static let automaticShutdownBusyRetryNanoseconds: UInt64 = 5_000_000_000
    private static let enabledAtFutureTolerance: TimeInterval = 5 * 60
    private static let operationWaitNanoseconds: UInt64 = 100_000_000
    /// How long quitting waits for an in-flight operation before going ahead.
    /// Chosen, not measured (docs/ARCHITECTURE.md).
    private static let quitBusyTimeout: TimeInterval = 30
    /// Quitting on Intel stays alive behind a closed lid so the virtual carrier
    /// and its watchdog survive until the panel can be restored.
    private static let terminationLidPollNanoseconds: UInt64 = 500_000_000
    private static let caffeinateExitPollNanoseconds: UInt64 = 50_000_000
    private static let caffeinateExitPollAttempts = 20
    private static let screenLockPollNanoseconds: UInt64 = 1_000_000_000
    private static let screenLockPollAttempts = 30
    private static let privilegeProbeInterval: TimeInterval = 15

    /// How often the SMC is sampled while the window or the popover is on
    /// screen. Chosen, not measured (docs/ARCHITECTURE.md) — it matches the panel tick, so
    /// the strip moves at the same rate as everything else on screen.
    private static let sensorSampleInterval: TimeInterval = 5
    /// The cadence with both surfaces closed. Sampling cannot simply stop:
    /// opening the popover must not show a stale strip for five seconds.
    /// Chosen, not measured (docs/ARCHITECTURE.md).
    private static let sensorIdleInterval: TimeInterval = 60
    /// A sample still outstanding after this long is stuck in the kernel, not
    /// slow. `IOConnectCallStructMethod` has no timeout and cannot be
    /// cancelled, so the only available response is to stop asking — see
    /// `sampleSensors()`.
    ///
    /// Was ten seconds, which fired on healthy hardware. A read measures about
    /// 80 ms here (0.7 s on the first call, which enumerates the keys), but the
    /// first sample after launch was measured at 2.8 s of wall clock on an idle
    /// machine — the work is trivial and the *scheduling* is not, with the main
    /// thread and several utility probes all live at once. Ten seconds left
    /// almost no margin above that for a machine actually under load, and the
    /// penalty for guessing wrong is permanent: the strip dies for the life of
    /// the process.
    ///
    /// A minute is not a measurement either, but the asymmetry is the point. A
    /// genuinely wedged IOKit call never returns at all, so waiting longer only
    /// delays a verdict that is still correct; waiting too little is wrong in a
    /// way nothing recovers from. `progress` already keeps a busy main actor or
    /// a starved sampling thread from ever reaching this clock.
    private static let sensorAbandonAfter: TimeInterval = 60

    /// Must match `RESCUE_BIN` in build.sh and `rescue_display` in lidless.sh.
    private static let rescueBinaryName = "lidless-display-rescue"
    /// Measured activation is 30-60 ms; the budget is for a window server that is
    /// busy, which does happen — a remote-desktop session establishing at the same
    /// moment made one attempt miss by three seconds.
    private static let panelWaitTimeout: TimeInterval = 5
    /// Leaving the active list is a local bookkeeping change, not a mode set, and
    /// was never observed taking anything like this long.
    private static let panelDisableWaitTimeout: TimeInterval = 3
    /// How often the heartbeat file is touched while a blackout is held. Chosen,
    /// not measured (docs/ARCHITECTURE.md): four touches inside
    /// `DisplayRescue.heartbeatStaleAfter` (25 s), so a single missed tick — a
    /// busy queue, a slow disk — cannot be mistaken for a hung owner. Its
    /// cross-file twin is that constant; the two only make sense read together.
    private static let panelHeartbeatInterval: TimeInterval = 5
    /// Deadline for the bundled rescue sweep. Generous — it sleeps 3.5 s of its own
    /// and then makes 32 display calls — but finite, because one caller is the quit
    /// path. Chosen, not measured (docs/ARCHITECTURE.md).
    private static let rescueToolTimeout: TimeInterval = 30
    private static let rescueToolPollNanoseconds: UInt64 = 200_000_000
    private static let rescueToolKillGrace: TimeInterval = 2
    /// How long to let the recovery watchdog prove it is still alive before the
    /// panel is touched. Long enough to catch an immediate exit — a wrong-arch or
    /// argument-refusing binary is gone in single-digit milliseconds — and short
    /// enough not to be felt in a lid close. Chosen, not measured (docs/ARCHITECTURE.md).
    private static let watchdogReadinessTimeoutNanoseconds: UInt64 = 3_000_000_000
    private static let watchdogReadinessPollNanoseconds: UInt64 = 25_000_000
    /// One `ioreg` a second, and only while the panel is actually held down.
    /// See `startPanelLidWatch` for why the notification observers cannot carry
    /// this on their own.
    private static let panelLidWatchInterval: TimeInterval = 1
    /// Past this, a lid probe is worth a line. Set just under the watch interval
    /// so anything that makes the one-second timer skip a tick is recorded, and
    /// nothing faster is — the healthy call measured 53–56 ms.
    private static let lidProbeSlowThreshold: Duration = .milliseconds(900)
    /// `caffeinate -u -t 1` returns before the display domain has actually come
    /// up; measured, a commit issued too early still fails with 1014.
    private static let panelWakeSettleNanoseconds: UInt64 = 1_500_000_000
    /// A Mac that has refused thirty times in a row is telling us something, and
    /// hammering it is exactly how the virtual-display churn of 2026-08-01
    /// started — five creations in ten seconds left this machine with no display
    /// at all. See docs/ARCHITECTURE.md
    private static let panelAttemptCap = 30
    private static let panelBackoffStep: TimeInterval = 2
    private static let panelBackoffCeiling: TimeInterval = 15
    /// Minimum gap between two virtual displays, whatever the reason for the
    /// second. Five creations in ten seconds is what left this Mac with the
    /// built-in missing from all three display lists and took the power button to
    /// recover (docs/ARCHITECTURE.md) — so this is a hard floor on the one operation with
    /// that history, not a retry policy. Chosen, not measured (docs/ARCHITECTURE.md).
    private static let virtualDisplayReapplyFloor: TimeInterval = 10
    private static let virtualDisplayChurnWindow: TimeInterval = 300
    private static let virtualDisplayChurnLimit = 6
    /// How long an unreadable display list may persist before a held carrier is
    /// presumed gone. Long enough that a transient probe failure never reaches it,
    /// short enough that a closed-lid Mac on a remote session is not left dark for
    /// minutes. Chosen, not measured (docs/ARCHITECTURE.md).
    private static let carrierUnknownGrace: TimeInterval = 30

    private struct StateFileBackup {
        let path: String
        let data: Data
    }

    private enum ScreenLockCommandOutcome {
        case applied
        case rejected
        case timedOut
    }

    /// What happened inside the locked section that writes the screen-lock
    /// restore point. An enum rather than early returns because the section runs
    /// inside a closure holding the interprocess lock, and the messages must be
    /// emitted after it has been released — a `return` from inside would also
    /// have read as returning from `applyScreenLock` itself.
    private enum ScreenLockRestorePointWrite {
        case ready
        case invalidSavedValue
        case unknownCurrentValue
        case writeFailed
    }

    /// This tool used to be called "remote mode" and kept its state in
    /// `~/.remote_mode_*`. A session already running at the time of the rename
    /// would otherwise be stranded: Disable would not know there was anything to
    /// restore, and the saved Low Power Mode value would be lost, while the Mac
    /// carried on ignoring the lid. `lidless.sh` does the same thing, so
    /// whichever of the two runs first adopts the files.
    ///
    /// Safe to delete once no machine can still be carrying the old names.
    private func migrateLegacyState() {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        for suffix in ["caffeinate_pid", "screenlock_prev", "lowpower_prev", "enabled_at"] {
            let new = "\(home)/.lidless_\(suffix)"
            let old = "\(home)/.remote_mode_\(suffix)"
            if !fm.fileExists(atPath: new), fm.fileExists(atPath: old) {
                try? fm.moveItem(atPath: old, toPath: new)
            }
        }
    }

    init() {
        UserDefaults.standard.register(defaults: [
            Keys.keepAwakeOnBattery: true,
            Keys.screenLockDelay: 3600,
            Keys.shutdownAfterHours: 0,
            Keys.shutdownBelowBatteryPercent: 0,
            Keys.disableOnQuit: true,
            // Off. Every other default here is recoverable by pressing a button;
            // this one can leave a person looking at a black screen.
            Keys.blackoutBuiltinDisplay: false,
            // Which mode that off switch turns ON, once someone turns it on. The
            // registered value and `SystemProbe.panelMode`'s fallback are the same
            // constant on purpose — a value that has never been written and a value
            // that cannot be parsed should not mean two different things.
            Keys.panelMode: PanelMode.default.rawValue,
        ])
        migrateLegacyState()
        // The file has always been written alongside this legacy defaults value.
        // Do not recreate a missing file from the default: `lidless.sh off` may
        // already have ended that session, leaving the old Date stale.
        UserDefaults.standard.removeObject(forKey: Keys.legacyEnabledAt)
        // Keeps running while the panel is closed, so the watchdog still fires.
        heartbeat = Timer.scheduledTimer(
            withTimeInterval: Self.backgroundRefreshInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // `.common`, for the reason already written twice in this file for the
        // panel heartbeat and the lid watch: a plain `Timer` stops firing while
        // a menu is tracking or a modal is up. This is the timer those two are
        // the backstop FOR, and it was the one left out.
        if let heartbeat {
            RunLoop.main.add(heartbeat, forMode: .common)
        }
        observePanelEvents()
        adoptStrandedPanel()
        refresh()
        // Started here rather than from a view's `onAppear`, because the popover
        // shows the same readings and the window may never be opened at all.
        startSensorSampling()
    }

    // MARK: - Sensors
    //
    // Everything in this section is deliberately disconnected from the refresh
    // path. `IOConnectCallStructMethod` on AppleSMC has no timeout and cannot
    // be killed — the same class of call as the `ioreg` that wedged `refresh()`
    // on 2026-08-02 (SystemProbe.swift:17-24) — so it gets its own timer, its
    // own background task, and no way to reach `refreshInFlight`, the panel
    // heartbeat, or the blackout reconcile. See docs/SMC_SENSORS.md.

    private func startSensorSampling() {
        retimeSensorSampling()
        sampleSensors()
    }

    private func stopSensorSampling() {
        sensorTimer?.invalidate()
        sensorTimer = nil
    }

    /// Rebuilds the timer at whichever cadence the currently visible surfaces
    /// call for. Called on launch and whenever the window or popover opens or
    /// closes.
    private func retimeSensorSampling() {
        guard !sensorsAbandoned else { return }
        let interval: TimeInterval = sensorSurfacesVisible > 0
            ? Self.sensorSampleInterval
            : Self.sensorIdleInterval
        sensorTimer?.invalidate()
        sensorTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleSensors() }
        }
        // `.common`, for the same reason as every other timer in this file: a
        // plain Timer stops firing while a menu tracks, and the popover is
        // opened from a menu bar item.
        if let sensorTimer {
            RunLoop.main.add(sensorTimer, forMode: .common)
        }
    }

    /// Called by a UI surface appearing or disappearing. Counted rather than
    /// set, because the window and the popover can both be up at once.
    func sensorSurfaceDidAppear() {
        sensorSurfacesVisible += 1
        retimeSensorSampling()
        // Take one immediately: opening a surface should not show a
        // minute-old strip while the idle timer runs out.
        sampleSensors()
    }

    func sensorSurfaceDidDisappear() {
        sensorSurfacesVisible = max(0, sensorSurfacesVisible - 1)
        retimeSensorSampling()
    }

    private func sampleSensors() {
        guard !sensorsAbandoned else { return }

        // A sample dispatched more than `sensorAbandonAfter` ago is not on its
        // own evidence of anything. This app blocks the MAIN ACTOR on purpose —
        // `executePrivileged` runs `pmset` synchronously from `performEnable`
        // under `Shell.defaultTimeout`, twice the abandon deadline — and both
        // this tick and the sample's completion have to land on it. Worse, the
        // sampling task is `.background` QoS, so it may not even have been
        // given a thread yet. Either way the wall clock keeps running while the
        // SMC, which answers in about 80 ms here, is asked nothing at all. That
        // is how a healthy Mac ended up with a permanently dark strip after an
        // ordinary Enable. Only the sampling thread can tell the difference,
        // which is what `progress` is for.
        let elapsed: TimeInterval = sensorSampleStartedAt.map { Date().timeIntervalSince($0) }
            // No start time with a sample in flight should not be possible; if
            // it ever is, do not read it as "zero seconds elapsed" and wait
            // forever on a call that may really be wedged.
            ?? .greatestFiniteMagnitude
        let progressSoFar: SensorSampleProgress? = sensorSampleProgress
        let verdict: SensorSampleVerdict = SensorSampling.sampleVerdict(
            inFlight: sensorSampleInFlight,
            elapsed: elapsed,
            callStarted: progressSoFar?.hasStarted ?? false,
            callReturned: progressSoFar?.hasReturned ?? false,
            abandonAfter: Self.sensorAbandonAfter
        )
        switch verdict {
        case .start:
            break
        case .wait:
            // Slow, not stuck. Skip this tick and let it finish.
            return
        case .resetClock:
            sensorSampleStartedAt = Date()
            return
        case .abandon:
            // Stuck in the kernel. The call cannot be cancelled, so the only
            // available response is to stop asking and stop presenting the
            // numbers as live. This is one-way for the life of the process:
            // without that, a Mac whose SMC hangs accumulates one stuck thread
            // per tick, and this app is expected to run unattended for days.
            // The cost is a permanently dead strip on such a machine, which is
            // the honest outcome — a retry loop would not be.
            //
            // Recorded, because it is invisible otherwise: the strip says only
            // "relaunch", and the two occasions this fired without a wedged SMC
            // behind it both had to be diagnosed by reading the source. A line
            // here says which of the three clocks ran out.
            PanelLog.event(
                "sensors abandoned after \(String(format: "%.1f", elapsed))s — "
                    + "call started: \(progressSoFar?.hasStarted ?? false), "
                    + "returned: \(progressSoFar?.hasReturned ?? false)"
            )
            sensorsAbandoned = true
            sensors.abandoned = true
            sensorSampleProgress = nil
            stopSensorSampling()
            return
        }

        sensorSampleInFlight = true
        sensorSampleStartedAt = Date()
        let progress = SensorSampleProgress()
        sensorSampleProgress = progress
        // `.utility`, like every other detached probe in this file, and NOT
        // `.background` — which is what this was, and which is why the strip
        // died. Background QoS is the one tier macOS is free to defer
        // indefinitely; on Apple Silicon it also pins the work to E-cores. At
        // launch, with the main thread busy and the utility probes running, the
        // sampling thread got so little CPU that a read measured at 80 ms
        // outside the app took over ten seconds inside it — and the deadline
        // below, which exists to catch a wedged kernel, caught this instead.
        // Nothing about the SMC was wrong on either occasion.
        Task.detached(priority: .utility) {
            // Both marks are made on this thread, before anything tries to hop
            // back to a main actor that may be blocked — that is the whole
            // point of them.
            progress.markStarted()
            let startedAt = Date()
            let readings: SensorReadings = SMCConnection.read()
            progress.markReturned()
            // A sample that took whole seconds did not fail, so nothing is said
            // on screen about it — but it is the near miss before an abandon,
            // and the abandon is the thing nobody could explain.
            let took: TimeInterval = Date().timeIntervalSince(startedAt)
            if took > 1 {
                PanelLog.event("sensors slow sample: \(String(format: "%.1f", took))s")
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.sensorSampleInFlight = false
                self.sensorSampleStartedAt = nil
                self.sensorSampleProgress = nil
                // A late arrival after abandonment is discarded: the strip has
                // already said it stopped, and replacing that with a number
                // would claim a liveness this sampler no longer has.
                guard !self.sensorsAbandoned else { return }
                self.sensors = readings
            }
        }
    }

    /// Until Panel blackout there was no lid or display event source in this app
    /// at all — the 60-second heartbeat above was the only thing that ever
    /// noticed the world had changed, so putting the panel back on lid-open would
    /// have taken up to a minute of staring at a dark screen.
    ///
    /// Both notifications only ask for a refresh; `apply` reconciles from the
    /// state it reads, so a notification this app caused by reconfiguring
    /// displays itself costs one extra probe and decides nothing. The heartbeat
    /// stays as the backstop: whether either notification fires for lid movement
    /// on a clamshell Mac is NOT verified — see docs/ARCHITECTURE.md
    private func observePanelEvents() {
        let refreshOnMain: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        panelObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main,
                using: refreshOnMain
            )
        )
        panelObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main,
                using: refreshOnMain
            )
        )
        // The display domain sleeping takes EVERY display out of the active
        // list, the virtual carrier included — measured 2026-08-04, the list
        // emptied entirely and refilled on wake with no display destroyed. Until
        // this was observed, that emptying read as "the session has no display"
        // and cost a night of tear-down-and-rebuild.
        //
        // The flag is set BEFORE the refresh in both directions on purpose: the
        // refresh is what asks for a carrier verdict, and a verdict taken with a
        // stale flag is the bug this exists to remove.
        panelObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.screensDidSleepNotification,
                object: nil,
                queue: .main,
                using: { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.displayDomainAsleep = true
                        PanelLog.event("display domain: asleep — \(self.panelStateLine)")
                        self.refresh()
                    }
                }
            )
        )
        panelObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main,
                using: { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.displayDomainAsleep = false
                        PanelLog.event("display domain: awake — \(self.panelStateLine)")
                        self.refresh()
                    }
                }
            )
        )
    }

    /// A marker left behind by a previous run of this app — one that crashed, was
    /// killed, or was quit while the Mac was powering off.
    ///
    /// Two things may need putting back, and both really do.
    ///
    /// The DISABLE, because it is not reverted when its owner dies — that belief
    /// was disproved on 2026-08-01 and is why `performRestorePanel` re-enables
    /// the display rather than assuming macOS already did. After a reboot it is
    /// moot (the configuration does not persist), but after a crash the app can
    /// be restarted into a Mac whose panel is still off.
    ///
    /// The BRIGHTNESS is no longer part of this. Blackout stopped changing it on
    /// 2026-08-02 (see `performBlackout`), so a stranded panel is stranded at the
    /// user's own level and a reboot inherits exactly that. The marker's
    /// brightness value survives as recovery's fallback for a panel found dark by
    /// some other means, not as something this feature has to undo.
    private func adoptStrandedPanel() {
        // A heartbeat file at launch is USUALLY a leftover: this app has just
        // started and is holding nothing. Verified live on 2026-08-01 — a
        // `kill -9` mid-blackout never reaches `stopPanelWatchdog`, so the file
        // outlived the process that owned it.
        //
        // Usually, not always. That premise is single-instance, and nothing here
        // enforces single-instance: `open -n`, running the binary in `build/`
        // directly, or a second copy in `~/Applications` all produce two. This
        // used to delete the file unconditionally, so instance #2 deleted
        // instance #1's heartbeat, #1's watchdog read the absence as infinitely
        // stale, and a working blackout was swept out from under it. So the
        // mtime decides — see `SystemProbe.strandedHeartbeatDecision`.
        //
        // Deleting a genuinely dead instance's file is still the right thing to
        // do even if its watchdog somehow outlived it: a missing heartbeat reads
        // as infinitely stale, so that watchdog fires, makes displays visible,
        // and exits. Safe direction, owner gone either way.
        let heartbeatAge: TimeInterval? = (try? FileManager.default.attributesOfItem(
            atPath: displayHeartbeatFile
        ))?[.modificationDate].flatMap { $0 as? Date }.map { Date().timeIntervalSince($0) }
        if SystemProbe.strandedHeartbeatDecision(age: heartbeatAge) == .liveOwner {
            let detail: String = heartbeatAge.map { String(format: "%.1fs", $0) } ?? "unknown"
            PanelLog.event(
                "adopt: declined — heartbeat is live (age \(detail)); another Lidless instance owns the panel"
            )
            message = "Another Lidless instance is already running and holding the built-in screen. This one will not touch it — quit the other instance first, or use the one that is already open."
            return
        }
        try? FileManager.default.removeItem(atPath: displayHeartbeatFile)
        try? FileManager.default.removeItem(
            atPath: displayHeartbeatFile + SystemProbe.displayWatchdogReadySuffix
        )

        guard FileManager.default.fileExists(atPath: displayFile) else { return }
        restorePanel(automatic: true)
    }

    // MARK: Reading state

    func refresh() {
        if busy || refreshInFlight {
            refreshRequested = true
            return
        }

        refreshInFlight = true
        refreshRequested = false
        let revision: UInt64 = stateRevision
        let pidFile: String = self.pidFile
        let now: Date = Date()
        let shouldProbePrivileges: Bool
        if let lastPrivilegeProbeAt: Date = lastPrivilegeProbeAt {
            shouldProbePrivileges = now.timeIntervalSince(lastPrivilegeProbeAt)
                >= Self.privilegeProbeInterval
        } else {
            shouldProbePrivileges = true
        }
        let privilegedSupportOverride: Bool? = shouldProbePrivileges
            ? nil
            : state.privilegedSupportInstalled
        if shouldProbePrivileges {
            lastPrivilegeProbeAt = now
        }
        Task.detached(priority: .utility) {
            let snapshot: SystemState = SystemProbe.read(
                pidFile: pidFile,
                privilegedSupportOverride: privilegedSupportOverride
            )
            await MainActor.run {
                self.refreshInFlight = false
                if revision == self.stateRevision && !self.busy {
                    self.apply(snapshot)
                } else {
                    self.refreshRequested = true
                }

                if self.refreshRequested && !self.busy {
                    self.refresh()
                }
            }
        }
    }

    /// Declarative rather than a paired take/release, and deliberately so.
    ///
    /// Every earlier attempt in this file to pair an acquire with a release on
    /// "all the exit paths" grew a path that was missed — the interprocess lock
    /// leaked into `caffeinate` exactly that way. This is driven from the state
    /// instead: called on every refresh and after every arm and restore, it
    /// converges on the right answer even if some future branch forgets it.
    /// Idempotent, so calling it often is free.
    private func updateDisplaySleepAssertion() {
        let needed: Bool = panelOwnedByThisApp && panelHeldMode == .virtualDisplay
        if needed, displaySleepAssertion == nil {
            var id: IOPMAssertionID = 0
            let rc: IOReturn = IOPMAssertionCreateWithName(
                kIOPMAssertionTypeNoDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Lidless is showing this session on a virtual display" as CFString,
                &id
            )
            if rc == kIOReturnSuccess {
                displaySleepAssertion = id
                PanelLog.event("display sleep: held off while the virtual display carries the session")
            } else {
                // Not fatal, and not silent. Without it the carrier can be
                // switched off by display sleep; `CarrierState.asleep` still
                // stops that becoming a churn loop, so the failure costs a dark
                // remote session rather than the machine.
                PanelLog.failure("display sleep: assertion refused (IOReturn \(rc)) — the carrier may sleep")
            }
        } else if !needed, let held = displaySleepAssertion {
            IOPMAssertionRelease(held)
            displaySleepAssertion = nil
            PanelLog.event("display sleep: released")
        }
    }

    private func apply(_ snapshot: SystemState) {
        state = snapshot
        hasCompletedFirstRead = true
        // "External" means the watchdog's, so a pending file this app wrote for
        // its own countdown (see `writeShutdownPendingFile`) does not count —
        // otherwise every app-armed shutdown would also light up as a second,
        // LaunchAgent-owned one.
        externalAutomaticShutdownPending = !automaticShutdownPending
            && FileManager.default.fileExists(atPath: shutdownPendingFile)
        sessionStartedAt = readEnabledAt()
        updateDisplaySleepAssertion()
        readPanelPresentation()
        checkWatchdog()
        reconcilePanelBlackout()
    }

    // MARK: Watchdog

    /// Powers the Mac off when a configured limit is reached. Only runs while
    /// the app is alive; the optional LaunchAgent enforces the same limits
    /// after the app has quit.
    private func checkWatchdog() {
        guard !busy, !automaticShutdownPending, !externalAutomaticShutdownPending else {
            return
        }

        let fileManager: FileManager = FileManager.default
        let hasSessionEvidence: Bool = state.keepAwakeActive
            || fileManager.fileExists(atPath: pidFile)
            || fileManager.fileExists(atPath: enabledAtFile)
        guard SystemProbe.shouldEvaluateAutoOffLimits(
            lidPresentation: state.lidPresentation,
            hasSessionEvidence: hasSessionEvidence
        ) else {
            return
        }

        let now: Date = Date()
        if let lastAttempt: Date = lastAutomaticShutdownAttempt,
           now.timeIntervalSince(lastAttempt) < Self.automaticShutdownRetryInterval {
            return
        }

        let defaults: UserDefaults = UserDefaults.standard
        let hours: Int = defaults.integer(forKey: Keys.shutdownAfterHours)
        if hours > 0 {
            if hasSessionEvidence {
                ensureEnabledAt(reset: false, now: now)
            }
            if hasSessionEvidence, let started: Date = readEnabledAt(),
               now.timeIntervalSince(started) >= Double(hours) * 3600 {
                scheduleAutomaticShutdown(trigger: .hours(hours))
                return
            }
        }

        let threshold: Int = defaults.integer(forKey: Keys.shutdownBelowBatteryPercent)
        if threshold > 0,
           state.powerSourceReadable,
           state.onBattery,
           let percent: Int = state.batteryPercent,
           percent <= threshold {
            scheduleAutomaticShutdown(trigger: .batteryPercent(percent))
        }
    }

    private func scheduleAutomaticShutdown(trigger: SystemProbe.AutomaticShutdownTrigger) {
        guard automaticShutdownGraceTask == nil else { return }
        let reason: String = trigger.reason
        lastAutomaticShutdownAttempt = Date()
        automaticShutdownPending = true
        automaticShutdownDeadline = Date().addingTimeInterval(
            Double(Self.automaticShutdownGraceNanoseconds) / 1_000_000_000
        )
        // The countdown is written to disk, not only held in memory. Without
        // this, `lidless.sh off` and `lidless.sh cancel-shutdown` could not see
        // an app-armed shutdown at all: both go through
        // `cancel_pending_shutdown`, which returns 1 on a missing file and is
        // called with `|| true`, so the terminal printed a clean teardown and
        // the Mac powered off anyway. The watchdog has always written this file
        // (`tools/lidless-check.sh`); only the app's half was missing. Same
        // one-line epoch format, which nothing parses but README documents.
        writeShutdownPendingFile()
        message = "Automatic shutdown in 60 seconds \(reason). Save your work or cancel."
        Shell.notify(
            "Mac will shut down in 60 seconds",
            "Lidless limit reached \(reason). Open Lidless and press Cancel shutdown to stop it."
        )

        armAutomaticShutdownGrace(
            trigger: trigger, nanoseconds: Self.automaticShutdownGraceNanoseconds
        )
    }

    /// The sleep at the end of an armed countdown, and everything that has to be
    /// true before it fires. Separate from `scheduleAutomaticShutdown` because
    /// the `busy` path below re-arms it without re-announcing anything.
    private func armAutomaticShutdownGrace(
        trigger: SystemProbe.AutomaticShutdownTrigger, nanoseconds: UInt64
    ) {
        automaticShutdownGraceTask = Task { @MainActor [weak self] in
            try? await Task<Never, Never>.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }

            // Somebody cancelled from a terminal while this was sleeping. The
            // CLI writes the cancel file; nothing in the app was reading it.
            if FileManager.default.fileExists(atPath: self.shutdownCancelFile) {
                self.clearAutomaticShutdownCountdown()
                try? FileManager.default.removeItem(atPath: self.shutdownCancelFile)
                self.lastAutomaticShutdownAttempt = Date()
                self.message = "Automatic shutdown cancelled from the command line. A still-exceeded limit may retry in five minutes."
                Shell.notify("Automatic shutdown cancelled", "Lidless remains active.")
                return
            }

            // A mutating operation is in flight. `automaticShutdown` would take
            // one look at `busy`, return, and leave nothing behind — no message,
            // no notification, no countdown — after the user had been told the
            // Mac was powering off. Hold the countdown and try again shortly.
            if self.busy {
                self.automaticShutdownGraceTask = nil
                self.setProgressMessage(
                    "Automatic shutdown \(trigger.reason) is waiting for the operation in progress to finish."
                )
                self.armAutomaticShutdownGrace(
                    trigger: trigger, nanoseconds: Self.automaticShutdownBusyRetryNanoseconds
                )
                return
            }

            if !self.automaticShutdownStillWarranted(trigger: trigger) {
                self.clearAutomaticShutdownCountdown()
                self.lastAutomaticShutdownAttempt = Date()
                self.message = "Automatic shutdown abandoned — the limit that triggered it (\(trigger.reason)) no longer applies."
                Shell.notify(
                    "Automatic shutdown abandoned",
                    "The condition that triggered it no longer applies. Lidless remains active."
                )
                return
            }

            self.clearAutomaticShutdownCountdown()
            self.automaticShutdown(reason: trigger.reason)
        }
    }

    /// Re-reads the live state and asks the pure rule whether the trigger still
    /// holds. The limits are re-read too, so clearing one during the grace also
    /// abandons the shutdown.
    private func automaticShutdownStillWarranted(
        trigger: SystemProbe.AutomaticShutdownTrigger
    ) -> Bool {
        let fileManager: FileManager = FileManager.default
        let hasSessionEvidence: Bool = state.keepAwakeActive
            || fileManager.fileExists(atPath: pidFile)
            || fileManager.fileExists(atPath: enabledAtFile)
        let defaults: UserDefaults = UserDefaults.standard
        return SystemProbe.automaticShutdownStillWarranted(
            trigger: trigger,
            hasSessionEvidence: hasSessionEvidence,
            sessionElapsed: readEnabledAt().map { Date().timeIntervalSince($0) },
            hoursLimit: defaults.integer(forKey: Keys.shutdownAfterHours),
            powerSourceReadable: state.powerSourceReadable,
            onBattery: state.onBattery,
            batteryPercent: state.batteryPercent,
            batteryThreshold: defaults.integer(forKey: Keys.shutdownBelowBatteryPercent)
        )
    }

    /// Tears the countdown down on every path that ends one — fired, abandoned
    /// or cancelled — including the on-disk half, so the CLI and the app never
    /// disagree about whether a shutdown is pending.
    private func clearAutomaticShutdownCountdown() {
        automaticShutdownGraceTask = nil
        automaticShutdownPending = false
        automaticShutdownDeadline = nil
        try? FileManager.default.removeItem(atPath: shutdownPendingFile)
        externalAutomaticShutdownPending = false
    }

    /// Mirrors `tools/lidless-check.sh`: one decimal epoch line, the moment the
    /// grace expires. Nothing reads the content — both sides treat the file as
    /// an existence flag — but writing the same thing keeps `README.md`'s
    /// description of the file honest.
    private func writeShutdownPendingFile() {
        let deadline: Int = Int(
            Date().timeIntervalSince1970
                + Double(Self.automaticShutdownGraceNanoseconds) / 1_000_000_000
        )
        do {
            try "\(deadline)\n".write(
                toFile: shutdownPendingFile, atomically: true, encoding: .utf8
            )
        } catch {
            // Not fatal to the countdown, which lives in memory — but it does
            // mean the CLI cannot see or cancel it, so say so rather than
            // leaving the user with a cancel command that silently does nothing.
            appendMessage(
                "The countdown could not be published to \(shutdownPendingFile) (\(error.localizedDescription)); cancelling from a terminal will not work — use Cancel shutdown in the app."
            )
        }
    }

    func cancelAutomaticShutdown() {
        let hadLocalPending: Bool = automaticShutdownGraceTask != nil
        automaticShutdownGraceTask?.cancel()

        let fileManager: FileManager = FileManager.default
        // A pending file this app wrote itself is not a watchdog shutdown, and
        // must not be answered with a cancel file — the watchdog is not sleeping
        // on one. Cancelling the in-memory task above is the whole cancellation
        // in that case.
        let hadExternalPending: Bool = !hadLocalPending
            && fileManager.fileExists(atPath: shutdownPendingFile)
        // The cancel file first, the teardown after it. Tearing down first would
        // delete the pending file — the only evidence `lidless.sh status` and
        // this app have that a shutdown is coming — and then, if the write
        // below failed, leave both surfaces reporting nothing pending while the
        // watchdog powered the Mac off anyway. On the failure path the
        // countdown is deliberately left standing, because it is still true.
        if hadExternalPending {
            do {
                try "cancel\n".write(
                    toFile: shutdownCancelFile,
                    atomically: true,
                    encoding: .utf8
                )
            } catch {
                // The one failed write in this app that must not be a quiet
                // string in a panel the user may not have open: the LaunchAgent
                // watchdog is mid-sleep and will power the Mac off in seconds
                // unless it finds that file. The user pressed Cancel shutdown and
                // is entitled to know it did not take.
                let detail: String = error.localizedDescription
                message = "Could not request cancellation of the watchdog shutdown: \(detail)"
                Shell.notify(
                    "Cancel shutdown FAILED",
                    "Lidless could not write \(shutdownCancelFile) (\(detail)). The Mac will still power off — run 'lidless.sh cancel-shutdown' now."
                )
                return
            }
        }
        clearAutomaticShutdownCountdown()

        if hadLocalPending || hadExternalPending {
            lastAutomaticShutdownAttempt = Date()
            message = "Automatic shutdown cancelled. A still-exceeded limit may retry in five minutes."
            Shell.notify("Automatic shutdown cancelled", "Lidless remains active.")
        }
    }

    private func automaticShutdown(reason: String) {
        guard !busy else { return }
        beginAction(clearMessage: false)
        Task { @MainActor in
            guard let lockFD = SystemProbe.acquireLock(path: lockFile) else {
                // Quiet: this runs unattended off the heartbeat timer. A
                // concurrent CLI/app operation already has the situation
                // handled — the next heartbeat tick retries on its own,
                // no need to alarm anyone over a routine, self-resolving race.
                finishAction()
                return
            }
            defer { SystemProbe.releaseLock(lockFD) }

            // Before the session files are staged, and deliberately NOT by adding
            // the marker to that staging list.
            //
            // The screen-lock precedent below REFUSES the shutdown when it cannot
            // put its value back, because a relaxed lock is a security regression
            // that persists and only an account password can undo. A dark panel is
            // neither: the disable is app-scoped and does not persist across a
            // restart, so what a reboot inherits is a normal screen at the user's
            // own level. So this one warns and carries on — and the marker is
            // deliberately left on disk, because it is what tells the next launch
            // there was a blackout to adopt.
            //
            // In `.dim` ("Keep panel on") brightness IS touched — 0.01, which
            // macOS persists across a reboot — so for that mode the marker is
            // load-bearing rather than merely informative, and the message below
            // is the honest description of what was left behind. The call right
            // after this comment, `performRestorePanel`, is exactly the function
            // that puts it back; an earlier version of this comment justified the
            // carry-on with a blanket "brightness is never touched", which was
            // true of `.virtualDisplay` only.
            await performRestorePanel(reason: "before automatic shutdown")
            if hasPanelToRestore {
                appendMessage(
                    "The built-in panel's brightness was not raised before shutdown; the restore point was kept and Lidless will bring the screen back to a readable level at its next launch."
                )
            }

            if await screenLockIsSafeForAutomaticShutdown() == false {
                message = "Automatic shutdown was cancelled because the screen-lock setting still needs an account-password restore. Press Disable first."
                Shell.notify(
                    "Automatic shutdown cancelled",
                    "Restore the Lidless screen-lock setting with Disable before using automatic shutdown."
                )
                finishAction()
                return
            }

            let lowPowerOutcome: (restored: Bool, warning: String?) =
                await restoreLowPowerForAutomaticShutdown()
            let additionalPaths: [String] = lowPowerOutcome.restored ? [lowPowerFile] : []
            guard let backups: [StateFileBackup] = stageSessionFilesForShutdown(
                additionalPaths: additionalPaths
            ) else {
                if lowPowerOutcome.restored {
                    reapplyLowPowerForActiveSession()
                }
                message = "Automatic shutdown could not safely clear its session files."
                Shell.notify(
                    "Automatic shutdown failed",
                    "Lidless could not prepare its session files; the Mac was not powered off."
                )
                finishAction()
                return
            }

            if let warning: String = lowPowerOutcome.warning {
                appendMessage(warning)
                Shell.notify("Lidless restore incomplete", warning)
            }

            let command = Shell.Command(SystemProbe.automaticShutdownHelperPath)
            let result: (ok: Bool, output: String) = Shell.runPrivilegedNonInteractive(command)
            guard result.ok else {
                let restored: Bool = restoreSessionFiles(backups)
                if lowPowerOutcome.restored {
                    reapplyLowPowerForActiveSession()
                }
                let detail: String = result.output.isEmpty
                    ? "Install automatic shutdown support from the README."
                    : result.output
                message = "Automatic shutdown failed \(reason) — \(detail)"
                if !restored {
                    appendMessage("The session files could not be fully restored; press Disable and verify the current state.")
                }
                Shell.notify(
                    "Automatic shutdown failed",
                    "The Mac was not powered off \(reason). Install or repair Lidless automatic shutdown support."
                )
                finishAction()
                return
            }

            // The helper asks the kernel to halt before its best-effort lid
            // cleanup. Keep the message accurate if shutdown teardown gives the
            // app one final UI cycle.
            setProgressMessage("Powering off \(reason).")
            finishAction()
        }
    }

    private func screenLockIsSafeForAutomaticShutdown() async -> Bool {
        let fileManager: FileManager = FileManager.default
        guard fileManager.fileExists(atPath: screenLockFile) else { return true }
        guard let saved: String = readSavedScreenLock() else { return false }

        let current: String = await Task.detached(priority: .utility) {
            SystemProbe.screenLock()
        }.value
        guard current == saved else { return false }
        removeScreenLockRestorePoint()
        return !fileManager.fileExists(atPath: screenLockFile)
    }

    private func restoreLowPowerForAutomaticShutdown() async -> (
        restored: Bool,
        warning: String?
    ) {
        let fileManager: FileManager = FileManager.default
        guard fileManager.fileExists(atPath: lowPowerFile) else {
            return (false, nil)
        }
        guard let saved: (ac: Int, battery: Int) = readSavedLowPower() else {
            return (
                false,
                "Saved Low Power Mode state is invalid; automatic shutdown will continue and keep the restore point."
            )
        }

        let snapshot: SystemState = await readFreshState()
        guard snapshot.powerSettingsReadable else {
            return (
                false,
                "Low Power Mode could not be restored before shutdown because power settings were unreadable; the restore point was kept."
            )
        }

        var commands: [Shell.Command] = [
            Shell.Command("/usr/bin/pmset", ["-c", "lowpowermode", String(saved.ac)])
        ]
        if snapshot.hasBattery {
            commands.append(
                Shell.Command("/usr/bin/pmset", ["-b", "lowpowermode", String(saved.battery)])
            )
        }
        let result: (ok: Bool, output: String) = Shell.runPrivilegedNonInteractive(commands)
        guard result.ok else {
            let detail: String = result.output.isEmpty ? "permission denied" : result.output
            return (
                false,
                "Low Power Mode was not restored before shutdown — \(detail). The restore point was kept."
            )
        }
        return (true, nil)
    }

    private func reapplyLowPowerForActiveSession() {
        guard UserDefaults.standard.bool(forKey: Keys.lowPowerWhileActive) else { return }
        let command = Shell.Command("/usr/bin/pmset", ["-a", "lowpowermode", "1"])
        let result: (ok: Bool, output: String) = Shell.runPrivilegedNonInteractive(command)
        if !result.ok {
            appendMessage(
                "Automatic shutdown failed, and Low Power Mode could not be re-enabled for the still-active session."
            )
        }
    }

    /// Remove the session files that would otherwise make a completed session look
    /// active after the next boot. Their exact bytes are retained in memory and
    /// restored if the helper is unavailable or denied by sudoers.
    private func stageSessionFilesForShutdown(
        additionalPaths: [String] = []
    ) -> [StateFileBackup]? {
        let fileManager: FileManager = FileManager.default
        let paths: [String] = [pidFile, enabledAtFile] + additionalPaths
        var backups: [StateFileBackup] = []
        backups.reserveCapacity(paths.count)

        for path: String in paths where fileManager.fileExists(atPath: path) {
            do {
                let data: Data = try Data(contentsOf: URL(fileURLWithPath: path))
                backups.append(StateFileBackup(path: path, data: data))
                try fileManager.removeItem(atPath: path)
            } catch {
                _ = restoreSessionFiles(backups)
                return nil
            }
        }
        return backups
    }

    @discardableResult
    private func restoreSessionFiles(_ backups: [StateFileBackup]) -> Bool {
        var restoredAll: Bool = true
        for backup: StateFileBackup in backups {
            do {
                try backup.data.write(
                    to: URL(fileURLWithPath: backup.path),
                    options: .atomic
                )
            } catch {
                restoredAll = false
            }
        }
        return restoredAll
    }

    // MARK: Panel blackout

    /// Whether anything is holding the built-in panel down, or claims to have.
    /// The marker counts on its own: it is the record a crashed previous run
    /// leaves behind, and the brightness in it is the only thing that knows what
    /// the screen looked like before.
    var hasPanelToRestore: Bool {
        // `panelRestoreUnconfirmed` is named here rather than left to imply itself
        // through the marker. The two are meant to travel together, but "meant to"
        // is an invariant nothing enforced — and if the marker is ever lost while
        // the flag is set, the flag becomes a state with no way out of it.
        panelOwnedByThisApp
            || panelRestoreUnconfirmed
            || FileManager.default.fileExists(atPath: displayFile)
    }

    /// Whether THIS process is currently holding the panel, in either mode.
    ///
    /// `panelBuiltinID`, not `panelVirtualDisplay`: `.dim` never creates a virtual
    /// display, so that flag reads nil throughout a perfectly healthy dim and
    /// every caller keyed to it concluded nobody was managing the panel. Both are
    /// set and cleared together on every path, so this is the same answer for
    /// `.virtualDisplay` and the only correct one for `.dim`.
    var panelOwnedByThisApp: Bool { panelBuiltinID != nil }

    /// `.gone`, or `.unknown` for long enough that pretending otherwise is its own
    /// failure. Used where the question is "should this be undone", never where it
    /// is "may this proceed" — proceeding still demands a confirmed `.alive`.
    var panelCarrierPresumedGone: Bool {
        // `ContinuousClock`, for the same reason `Shell.collect` and
        // `waitForActive` use it: a clock pushed backwards made this interval
        // negative, so the grace period never elapsed and a lost carrier was
        // suppressed for as long as the difference lasted.
        SystemProbe.panelCarrierPresumedGoneDecision(
            heldMode: panelHeldMode,
            carrierSnapshot: panelCarrierSnapshot,
            unknownSince: panelCarrierUnknownSince,
            now: .now,
            unknownGraceSeconds: Self.carrierUnknownGrace
        )
    }

    var panelCarrierState: CarrierState {
        SystemProbe.panelCarrierVerdict(
            carrier: panelVirtualDisplay.map { (terminated: $0.hasTerminated, displayID: $0.displayID) },
            activeDisplayIDs: DisplayAPI.activeDisplayIDs(),
            displayAsleep: displayDomainAsleep
        )
    }

    /// Whether anything is still going to put the panel back on its own.
    ///
    /// False once the recovery watchdog is gone or the retry budget is spent, and
    /// the window needs to know: its "holding the panel down" note promised "it
    /// comes back on its own when the lid opens", which outranked — and therefore
    /// hid — the message saying the attempts had run out. A reassurance shown on
    /// top of the warning that contradicts it is worse than either alone.
    var panelRecoveryIsAutomatic: Bool {
        SystemProbe.panelRecoveryIsAutomaticDecision(
            restoreUnconfirmed: panelRestoreUnconfirmed,
            ownedByThisApp: panelOwnedByThisApp,
            presentation: panelPresentation,
            watchdogRunning: panelWatchdog?.isRunning == true,
            attempts: panelAttempts,
            attemptCap: Self.panelAttemptCap
        )
    }

    /// What is actually in force, falling back to the setting when nothing is held.
    ///
    /// The picker stays live during a blackout, so `panelMode` alone answers "what
    /// would happen next time" — the window was using it to describe what IS
    /// happening, and flipping the picker mid-blackout relabelled a running
    /// `.virtualDisplay` as a dim.
    var panelEffectiveMode: PanelMode { panelHeldMode ?? panelMode }

    /// How to darken the panel. Read live rather than cached: the setting can
    /// change between a blackout and its restore, and the restore path is
    /// deliberately mode-agnostic so that costs nothing.
    var panelMode: PanelMode {
        SystemProbe.panelMode(in: UserDefaults.standard.string(forKey: Keys.panelMode))
    }

    /// Whether the private display API this feature is built on exists here. All
    /// of it is private, none of it is in a header, and a macOS update is allowed
    /// to take any of it away — so the reason travels to the UI verbatim.
    var panelBlackoutSupport: VirtualDisplaySupport { DisplayAPI.support }

    private func readSavedDisplayBrightness() -> Float? {
        guard let text = try? String(contentsOfFile: displayFile, encoding: .utf8) else {
            return nil
        }
        return SystemProbe.savedDisplayBrightness(in: text)
    }

    /// Reads the panel's state from the live display lists. Cheap enough to run
    /// on every refresh, and it has to be: this is the only thing that notices a
    /// blackout coming undone by itself.
    private func readPanelPresentation() {
        guard case .available = DisplayAPI.support else {
            panelPresentation = .unknown
            return
        }
        let builtin: UInt32? = DisplayAPI.builtinDisplayID()
        let builtinActive: Bool?
        if let builtin, let active: [UInt32] = DisplayAPI.activeDisplayIDs() {
            builtinActive = active.contains(builtin)
        } else {
            builtinActive = nil
        }
        let brightness: Float? = builtin.flatMap { DisplayAPI.brightness(of: $0) }

        // Remember what the panel looked like before anything touched it. This is
        // the only place that sees the brightness while the lid is still open —
        // by the time `performBlackout` runs, macOS has usually begun its own fade
        // and a reading there is too low (see `SystemProbe.markerBrightness`).
        //
        // Three conditions, all necessary. Not while this app holds the panel, or
        // it would record its own dimming. Not with the lid shut, which is when
        // the fade happens. And not below the visible floor, because a value that
        // low is indistinguishable from a sample caught mid-fade — the fresh
        // reading is the safer fallback there.
        //
        // `state.hasLid` is the readability check, not a desktop check: it is true
        // only when the `ioreg` output actually contained `AppleClamshellState`,
        // and `lidClosed` defaults to false when that read fails. Without it a
        // failed probe read as "the lid is open" and a value caught mid-fade could
        // be remembered as the user's own level and handed back to them later.
        if !panelOwnedByThisApp, state.hasLid, !state.lidClosed, let brightness,
           brightness >= SystemProbe.panelVisibleFloor {
            panelOpenLidBrightness = brightness
        }

        notePanelCarrierState()

        panelPresentation = SystemProbe.panelPresentation(
            builtinActive: builtinActive,
            brightness: brightness,
            blackoutOwnedByThisApp: panelOwnedByThisApp
        )
    }

    /// Panel blackout is a STANDING RULE, not a reaction to an event: "Lidless is
    /// on and the lid is shut" means the panel should be dark, and if it is not,
    /// try again. The spike's first version acted on the lid transition alone, and
    /// a single failed attempt — the window server was busy establishing a
    /// remote-desktop session — left the panel lit until the next time the lid
    /// moved, which is precisely the state this feature exists to prevent.
    private func reconcilePanelBlackout() {
        guard !busy else { return }
        guard case .available = DisplayAPI.support else { return }
        notePanelCarrierState()

        let fileManager: FileManager = FileManager.default

        // Holding the panel with no live watchdog is the exact state
        // `startPanelWatchdog` refuses to start in, so it must not be reachable by
        // outliving one either. The watchdog's own termination handler covers the
        // common case; this is the same check from the other end, on the timer,
        // for the case where it fired while an operation was in flight.
        //
        // Expressed as "not armed", not as a `restorePanel` call of its own. An
        // out-of-band call skips the attempt counter and the backoff below, and a
        // restore that keeps failing keeps ownership and the marker — so the next
        // refresh saw the same condition and called again, immediately, forever.
        // Folding it into the goal costs one term and inherits the cap.
        let watchdogLost: Bool = panelOwnedByThisApp && panelWatchdog?.isRunning != true

        // The virtual display that was carrying the session is gone while the
        // built-in is still switched off — nothing is showing anything. This is
        // the state `panelVirtualDisplayVanished` reacts to directly, but it
        // defers when an operation is in flight, and that deferral is exactly the
        // window in which nothing else noticed. Same treatment as a lost watchdog:
        // not armed, so it flows through the goal, the backoff and the cap.
        let sessionDisplayLost: Bool = panelOwnedByThisApp
            && panelHeldMode == .virtualDisplay
            && panelCarrierPresumedGone
        let goal: PanelGoal = SystemProbe.panelGoalDecision(
            watchdogLost: watchdogLost,
            sessionDisplayLost: sessionDisplayLost,
            blackoutEnabled: UserDefaults.standard.bool(forKey: Keys.blackoutBuiltinDisplay),
            isFullyOn: state.isFullyOn,
            hasLid: state.hasLid,
            lidClosed: state.lidClosed
        )

        if goal != panelGoal,
           SystemProbe.panelGoalDeferralDecision(
               currentGoal: panelGoal,
               proposedGoal: goal,
               watchdogLost: watchdogLost,
               sessionDisplayLost: sessionDisplayLost,
               isFullyOn: state.isFullyOn,
               hasLid: state.hasLid,
               lidClosed: state.lidClosed,
               alreadyDeferred: panelGoalDeferred
           ) {
            panelGoalDeferred = true
            PanelLog.event(
                "goal: \(panelGoal) -> \(goal) DEFERRED one refresh — reached through an"
                    + " absence, not an open lid (isFullyOn=\(state.isFullyOn)"
                    + " hasLid=\(state.hasLid) lidClosed=\(state.lidClosed)"
                    + " probesSkipped=\(state.probesSkippedForBudget)"
                    // D3a: a goal change driven by a slow read is a different
                    // animal from one driven by a fast, confident one.
                    + " readTook=\(state.readDuration))"
            )
            // Returning, not falling through with the old goal: everything below
            // acts on `goal`, so carrying on would do the very thing being
            // deferred. The cost is that this one tick also skips the lapse
            // check below — for a single refresh, and only on a reading that the
            // next one is expected to contradict.
            return
        }
        // Cleared whether the goal changed or not: agreement with the goal we
        // already hold is exactly as good a reason to stop deferring as acting
        // on a change would be.
        panelGoalDeferred = false

        if goal != panelGoal {
            // Before the assignment, so the line carries what it moved FROM. The
            // inputs come with it because the goal is derived, and a transition
            // nobody expected is only answerable by seeing what produced it.
            PanelLog.event(
                "goal: \(panelGoal) -> \(goal) (watchdogLost=\(watchdogLost)"
                    + " sessionDisplayLost=\(sessionDisplayLost) isFullyOn=\(state.isFullyOn)"
                    + " hasLid=\(state.hasLid) lidClosed=\(state.lidClosed)"
                    // The field that separates "this Mac has no clamshell key"
                    // from "nobody asked it". Both arrive here as hasLid=false.
                    + " probesSkipped=\(state.probesSkippedForBudget)"
                    // D3a: a goal change driven by a slow read is a different
                    // animal from one driven by a fast, confident one.
                    + " readTook=\(state.readDuration))"
            )
            panelGoal = goal
            panelAttempts = 0
            nextPanelAttempt = .now
            panelGaveUpReported = false
            // Once, on the transition. Repeating it every five seconds would bury
            // whatever the restore itself has to say.
            if watchdogLost {
                appendMessage(
                    "Panel blackout's recovery watchdog is no longer running, so the screen is not being held down without one. Putting the panel back."
                )
            } else if sessionDisplayLost {
                appendMessage(
                    "The virtual display carrying the session is gone while the built-in is still off. Putting the panel back."
                )
            }
        }

        switch goal {
        case .lit:
            guard hasPanelToRestore else { return }
            // Do not spend retry attempts — or enter the blocking private display
            // call — while an Intel panel is physically unavailable. The one-second
            // lid watcher refreshes state when it opens and this path resumes then.
            guard !shouldDeferPanelRestoreUntilLidOpen else { return }
        case .dark:
            // `panelOwnedByThisApp`, not `panelVirtualDisplay != nil`. `.dim` never
            // creates a virtual display, so keying on it meant a perfectly healthy
            // dim fell through to the re-apply below — where `performBlackout`
            // refuses because the panel is already held — every five seconds, one
            // wasted attempt at a time, until the retry budget ran out and the app
            // announced it had given up on a blackout that was working.
            if panelOwnedByThisApp {
                // Compare the goal against what is OBSERVED, never against our own
                // flag. Measured 2026-08-01: an app-scoped disable came undone by
                // itself around thirty seconds after being applied, with the lid
                // still shut and the owner still alive. A version that trusted its
                // bookkeeping stopped noticing.
                //
                // What "came undone" looks like depends on what is being held.
                // `.virtualDisplay` takes the built-in out of the active list, so
                // its return is the signal. `.dim` never removes it — the display
                // is there throughout — so the signal is the level coming back up.
                // An unreadable level is neither: re-dimming on a guess would
                // capture the wrong value as "the original" and lose the real one.
                let lapsed: Bool
                if panelHeldMode == .virtualDisplay {
                    lapsed = panelBuiltinID.map {
                        DisplayAPI.activeDisplayIDs()?.contains($0) ?? false
                    } ?? false
                } else {
                    lapsed = panelBuiltinID
                        .flatMap { DisplayAPI.brightness(of: $0) }
                        .map { $0 >= SystemProbe.panelVisibleFloor } ?? false
                }
                guard lapsed else { return }
                PanelLog.failure(
                    "the display configuration reverted by itself while the lid is shut"
                        + " — \(panelStateLine)"
                )
                // Lapsed. Drop everything we think we hold and start over, rather
                // than disabling a display on top of stale bookkeeping.
                //
                // Brightness goes back BEFORE the marker does. That ordering was
                // load-bearing while blackout dimmed the panel: the re-apply a few
                // lines below captures whatever it finds as "the original", so
                // clearing the marker first would have recorded 0.01 and lost the
                // real level permanently. Nothing dims any more, so a lapsed panel
                // is already at the user's own level and this reaches `.leaveAlone`
                // — but the ordering stays, because it is also what recovers a
                // panel some OTHER agent left dark, and getting it backwards is
                // silent when it is wrong.
                var readable: Bool = false
                var markerStuck: Bool = false
                if let lapsedBuiltin: UInt32 = panelBuiltinID {
                    switch SystemProbe.panelBrightnessDecision(
                        savedValue: readSavedDisplayBrightness(),
                        currentValue: DisplayAPI.brightness(of: lapsedBuiltin)
                    ) {
                    case .leaveAlone:
                        break
                    case .restore(let value):
                        _ = DisplayAPI.setBrightness(value, on: lapsedBuiltin)
                    }
                    // Same confirmation `performRestorePanel` makes, for the same
                    // reason and because otherwise it is pointless: this branch ran
                    // one tick later on a manual Restore that had deliberately kept
                    // the marker, and cleared it unconditionally. A guarantee with
                    // a second door in it is not a guarantee.
                    readable = DisplayAPI.brightness(of: lapsedBuiltin)
                        .map { $0 >= SystemProbe.panelVisibleFloor } ?? false
                }
                panelVirtualDisplay = nil
                panelBuiltinID = nil
                panelHeldMode = nil
                if readable {
                    panelRestoreUnconfirmed = false
                    stopPanelWatchdog()
                    try? fileManager.removeItem(atPath: displayFile)
                    // Only forgiven once the marker is genuinely gone — the same
                    // rule `performRestorePanel` follows, and this branch was
                    // quietly exempt from it.
                    if !SystemProbe.attemptForgivenessDecision(
                        markerStillPresent: fileManager.fileExists(atPath: displayFile)
                    ) {
                        markerStuck = true
                    }
                } else {
                    // Exactly the state `panelRestoreUnconfirmed` exists for, and
                    // this branch used to reach it the wrong way: it dropped
                    // ownership AND stopped the watchdog and heartbeat, keeping
                    // only the marker — stripping the safety net at the one moment
                    // nobody can confirm the screen is readable. Ownership goes,
                    // every net stays.
                    panelRestoreUnconfirmed = true
                    // Kept on purpose — which for the attempt budget is the same
                    // as stuck. Forgiving it here handed out a fresh set of
                    // attempts on every pass through the one branch that never
                    // finishes anything.
                    markerStuck = true
                    appendMessage(
                        "The display configuration reverted by itself and the panel's brightness could not be confirmed; its restore point and recovery watchdog were kept."
                    )
                }
                if !markerStuck {
                    panelAttempts = 0
                    nextPanelAttempt = .now
                    panelGaveUpReported = false
                }
                // Say so. This path used to run in complete silence, which cost a
                // real investigation on 2026-08-02: a blackout was seen tearing
                // itself down and rebuilding with the lid shut, and afterwards
                // there was no way to tell whether THIS fired or
                // `panelVirtualDisplayVanished` did — both leave exactly the same
                // trace in the display lists, and a two-second sampler cannot
                // catch the one frame that separates them. The other path already
                // announced itself; this one now does too, so the next occurrence
                // identifies itself instead of needing to be reasoned about.
                appendMessage("The display configuration reverted by itself; re-applying.")
            }
        }

        let attemptVerdict = SystemProbe.panelAttemptDecision(
            now: .now,
            nextAttempt: nextPanelAttempt,
            attempts: panelAttempts,
            attemptCap: Self.panelAttemptCap,
            goal: goal,
            hasPanelToRestore: hasPanelToRestore,
            gaveUpReported: panelGaveUpReported,
            backoffStep: Self.panelBackoffStep,
            backoffCeiling: Self.panelBackoffCeiling
        )
        switch attemptVerdict {
        case .wait:
            return
        case .capReached(let showMessage, let shouldEscalate):
            if showMessage {
                panelGaveUpReported = true
                appendMessage(
                    goal == .dark
                        ? "Panel blackout gave up after \(Self.panelAttemptCap) attempts; the panel was left lit."
                        : "The built-in panel could not be put back after \(Self.panelAttemptCap) attempts. Handing over to \(Self.rescueBinaryName)."
                )
            }
            // Giving up has to be a handover, not silence — but this app does it
            // ITSELF rather than by going quiet and letting the watchdog conclude
            // it has hung.
            //
            // Removing the heartbeat was the first attempt at that and it was
            // wrong: the watchdog's whole contract is "the owner is dead or
            // stuck", and this owner is neither. Two live parties then acted on
            // the same marker — the sweep deletes it on success, so an app that
            // started a fresh blackout in that window had its NEW restore point
            // removed by a sweep answering the OLD situation. Running the bounded
            // rescue here keeps one owner: same tool, same effect, no lie in the
            // protocol.
            if shouldEscalate {
                Task { @MainActor in await self.escalateToRescueTool() }
            }
            return
        case .proceed(let next):
            panelAttempts += 1
            nextPanelAttempt = next
        }

        switch goal {
        case .dark: blackOutPanel(automatic: true)
        case .lit: restorePanel(automatic: true)
        }
    }

    /// Same shape as `enable()`: reserve the controller, take the cross-process
    /// lock, re-read the world, act, release, refresh.
    func blackOutPanel(automatic: Bool = false) {
        guard !busy else { return }
        beginAction(clearMessage: !automatic)
        Task { @MainActor in
            guard let lockFD = SystemProbe.acquireLock(path: lockFile) else {
                if !automatic { message = Self.lockUnavailableMessage }
                finishAction()
                return
            }
            let initialState: SystemState = await readFreshState()
            state = initialState
            await performBlackout(initialState: initialState)
            SystemProbe.releaseLock(lockFD)
            finishAction()
        }
    }

    func restorePanel(automatic: Bool = false) {
        guard !busy else { return }
        beginAction(clearMessage: !automatic)
        Task { @MainActor in
            guard let lockFD = SystemProbe.acquireLock(path: lockFile) else {
                if !automatic { message = Self.lockUnavailableMessage }
                finishAction()
                return
            }
            await performRestorePanel(reason: automatic ? "automatically" : "on request")
            SystemProbe.releaseLock(lockFD)
            finishAction()
        }
    }

    /// The order below is the whole feature, and every step of it was paid for by
    /// a measurement on 2026-08-01 (docs/ARCHITECTURE.md):
    ///
    ///   1 create the virtual display        3 write the marker
    ///   2 confirm it in the active list     4 disable the built-in
    ///                                       5 confirm it left the active list
    ///
    /// **Nothing here touches brightness, and that is the measured choice.** This
    /// used to dim the panel to `panelDimLevel` between (3) and (4), because a
    /// 2026-08-01 measurement said disabling a display leaves its backlight lit.
    /// Re-measured 2026-08-02 with the dim removed: disabling the built-in drives
    /// its backlight register to 0 by itself and holds it there — 16 min on mains
    /// and 15 min on battery, one continuous zero, plus a human confirming a dark
    /// screen. The old claim predicted the backlight returning after about ten
    /// seconds; it never returned. See docs/ARCHITECTURE.md.
    ///
    /// Leaving brightness alone is also the better failure mode, which is why
    /// this is not merely a simplification: a crash now strands the panel at the
    /// user's own level rather than at 1 %, so it comes back readable with
    /// nothing to restore.
    ///
    /// The marker is still written, and still before the disable. Its brightness
    /// value stops mattering while nothing dims, but the FILE is what
    /// `adoptStrandedPanel` reads to know a blackout is in progress at all.
    ///
    /// Every display call here runs on the main actor. CoreGraphics display
    /// configuration is main-thread sensitive, and the waits are `async` so the
    /// UI, the refresh timer and the blackout heartbeat all keep running.
    private func performBlackout(initialState: SystemState) async {
        // Both, not just the virtual display: `.dim` never creates one, so that
        // flag alone would let a second dim start on top of a running one.
        guard panelVirtualDisplay == nil, panelBuiltinID == nil else { return }
        // Cleared here rather than on teardown: the note only suppresses repeats
        // WITHIN one blackout, and a new one has to be free to record the same
        // lid reading the previous one happened to end on.
        lastLidWatchNote = ""
        PanelLog.event("blackout: starting, mode=\(panelMode.rawValue)")
        if case .unavailable(let reason) = DisplayAPI.support {
            PanelLog.failure("blackout: unavailable on this Mac — \(reason)")
            message = "Panel blackout is not available on this Mac — \(reason)."
            return
        }
        // Re-checked against the state just read, not the state that started the
        // reconcile: acquiring the lock and probing take time, and the lid can be
        // opened in it.
        //
        // Logged, and the whole triple with it. This was the last silent exit in
        // the function, and on 2026-08-04 01:24:38 it produced a
        // `blackout: starting` with no terminal line at all — indistinguishable
        // in the record from the hang this instrument exists to catch.
        guard initialState.isFullyOn, initialState.hasLid, initialState.lidClosed else {
            PanelLog.event(
                "blackout: stood down before building — the state moved under it"
                    + " (isFullyOn=\(initialState.isFullyOn) hasLid=\(initialState.hasLid)"
                    + " lidClosed=\(initialState.lidClosed)"
                    + " probesSkipped=\(initialState.probesSkippedForBudget))"
            )
            return
        }
        guard let builtin: UInt32 = DisplayAPI.builtinDisplayID() else {
            PanelLog.failure("blackout: no built-in display could be named")
            message = "Panel blackout found no built-in display."
            return
        }

        if panelMode == .dim {
            await performDim(builtin: builtin)
            return
        }

        // Geometry comes from the panel itself. There is no fallback size on
        // purpose: a hardcoded one would be this machine's panel, and handing the
        // window server a mode the real display does not have is how the session
        // ends up somewhere nobody can see. Refusing leaves the screen lit, which
        // is always the safe direction.
        guard let mode: CGDisplayMode = CGDisplayCopyDisplayMode(builtin),
              mode.pixelWidth > 0, mode.pixelHeight > 0 else {
            PanelLog.failure("blackout: the built-in display's mode could not be read")
            message = "Panel blackout could not read the built-in display's mode."
            return
        }
        let millimetres: CGSize = CGDisplayScreenSize(builtin)
        guard millimetres.width > 0, millimetres.height > 0 else {
            PanelLog.failure("blackout: the built-in display's physical size could not be read")
            message = "Panel blackout could not read the built-in display's physical size."
            return
        }
        // Built-in panels commonly report 0 here, which is "variable", not "no
        // refresh rate". 60 is what the spike ran the whole verified cycle at.
        let refreshHz: Double = mode.refreshRate > 0 ? mode.refreshRate : 60

        // CGVirtualDisplaySettings.hiDPI has different observed semantics here.
        // Apple Silicon turns a physical-pixel mode into the matching point-sized
        // workspace. Intel exposes those same numbers as a 1x workspace, so use
        // the built-in mode's logical width/height on that slice instead. The app
        // is universal, therefore this branch is compiled independently into
        // each architecture rather than guessed from a model name at runtime.
        #if arch(x86_64)
        let usesPhysicalPixelMode = false
        #else
        let usesPhysicalPixelMode = true
        #endif
        guard let virtualMode = SystemProbe.virtualDisplayModeDimensions(
            logicalWidth: mode.width,
            logicalHeight: mode.height,
            pixelWidth: mode.pixelWidth,
            pixelHeight: mode.pixelHeight,
            usesPhysicalPixelMode: usesPhysicalPixelMode
        ) else {
            PanelLog.failure("blackout: the workspace size could not be determined")
            message = "Panel blackout could not determine the built-in display's workspace size."
            return
        }

        // A floor on how often a virtual display may be BUILT, independent of goals
        // and attempt counters, and checked before the constructor rather than
        // after it — a version of this that refused a display it had just created
        // would have throttled nothing at all. Refusing leaves the panel lit
        // behind a shut lid for a few seconds, which is the symptom this feature
        // removes; what it guards against is the failure that removes the screen.
        let now = Date()
        let churn = SystemProbe.virtualDisplayChurnDecision(
            history: recentVirtualDisplays,
            now: now,
            lastMonotonic: lastVirtualDisplayMonotonic,
            nowMonotonic: .now,
            reapplyFloor: Self.virtualDisplayReapplyFloor,
            churnWindow: Self.virtualDisplayChurnWindow,
            churnLimit: Self.virtualDisplayChurnLimit
        )
        // Written back unconditionally, not only computed. The getter clamps a
        // future stamp to "now" on every read without storing it, so after a
        // clock rollback one entry kept being re-clamped forward and never aged
        // out — the brake stayed on until real time caught up with the bad
        // value. Persisting the normalised form starts its five minutes here,
        // regardless of what happens next.
        recentVirtualDisplays = churn.prunedHistory
        switch churn.outcome {
        case .rateLimited:
            PanelLog.event("blackout: refused — a virtual display was built too recently")
            return
        case .ceilingReached:
            PanelLog.failure(
                "blackout: refused — \(Self.virtualDisplayChurnLimit) virtual displays built"
                    + " within \(Int(Self.virtualDisplayChurnWindow))s; pausing with the panel lit"
            )
            if !panelGaveUpReported {
                panelGaveUpReported = true
                // "Attempted", because the count is taken before the constructor
                // and a refused one never reconfigured anything. And "pausing",
                // not "stopped": the window ages out and attempts resume by
                // themselves, so promising a dead end would send people looking
                // for a restart the persisted counter is specifically there to
                // survive.
                appendMessage(
                    "Panel blackout has attempted to build its virtual display \(Self.virtualDisplayChurnLimit) times in \(Int(Self.virtualDisplayChurnWindow / 60)) minutes and is pausing. The panel was left lit; it will try again once those attempts age out. Open the lid, or switch to Keep panel on."
                )
                Shell.notify(
                    "Panel blackout is pausing",
                    "It has tried to build its virtual display too often. The screen was left lit."
                )
            }
            return
        case .proceed:
            recentVirtualDisplays = churn.prunedHistory + [now]
            lastVirtualDisplayMonotonic = .now
        }

        guard let virtual = VirtualDisplay(
            maxPixelsWide: UInt32(mode.pixelWidth),
            maxPixelsHigh: UInt32(mode.pixelHeight),
            modeWide: UInt32(virtualMode.width),
            modeHigh: UInt32(virtualMode.height),
            millimetresWide: Double(millimetres.width),
            millimetresHigh: Double(millimetres.height),
            refreshHz: refreshHz,
            onTerminated: { [weak self] id in
                // The ID travels with the callback so a late one from a display
                // that has already been replaced cannot clear its successor.
                Task { @MainActor in self?.panelVirtualDisplayVanished(id: id) }
            }
        ) else {
            PanelLog.failure("blackout: the virtual display could not be created")
            message = "Panel blackout could not create its virtual display."
            return
        }
        // Published before the FIRST await, not after it. Publishing after
        // `waitUntilActive` still lost a display that died while that call was
        // returning: the callback ran, found no reference, dropped — and the
        // continuation then published a corpse. Every early return from here on
        // has to clear this; that is what releases the display.
        panelVirtualDisplay = virtual

        guard await virtual.waitUntilActive(timeout: Self.panelWaitTimeout) else {
            panelVirtualDisplay = nil
            PanelLog.failure("blackout: the virtual display never activated — panel left alone")
            message = "Panel blackout's virtual display did not activate; the panel was left alone."
            return
        }

        let decision: BlackoutDecision = SystemProbe.blackoutDecision(
            activeDisplayIDs: DisplayAPI.activeDisplayIDs(),
            builtinID: builtin,
            virtualDisplayID: virtual.displayID
        )
        guard case .proceed(let confirmedBuiltin) = decision else {
            if case .refuse(let reason) = decision {
                PanelLog.failure("blackout: refused by the pre-flight decision — \(reason)")
                message = "Panel blackout refused: \(reason)."
            }
            panelVirtualDisplay = nil
            return
        }

        guard let saved: Float = SystemProbe.markerBrightness(
            lastOpenLid: panelOpenLidBrightness,
            currentReading: DisplayAPI.brightness(of: confirmedBuiltin)
        ) else {
            PanelLog.failure("blackout: the panel's brightness could not be read — no level to return to")
            message = "Panel blackout could not read the panel's brightness, so it would have no level to bring the screen back to. Nothing was changed."
            panelVirtualDisplay = nil
            return
        }
        // An inherited marker keeps its BRIGHTNESS, but the file is rewritten
        // regardless. `markerInheritDecision` still owns the brightness rule —
        // when `panelRestoreUnconfirmed` is set the panel may already be dark, so
        // a fresh reading can be that dark level, and only a marker whose
        // brightness can be READ BACK may displace it (`fileExists` was the wrong
        // test: a corrupt marker must not win over a valid fresh value). What
        // changed is that skipping the write entirely is no longer an option: the
        // second line has to name THIS carrier, and an inherited ID would make
        // rescue exclude a display that no longer exists.
        let savedOnDisk: Float? = readSavedDisplayBrightness()
        let markerBrightness: Float = SystemProbe.markerInheritDecision(
            restoreUnconfirmed: panelRestoreUnconfirmed,
            savedReadable: savedOnDisk != nil
        ) ? saved : (savedOnDisk ?? saved)
        do {
            try SystemProbe.displayRestoreMarker(
                brightness: markerBrightness,
                virtualDisplayID: virtual.displayID
            ).write(toFile: displayFile, atomically: true, encoding: .utf8)
        } catch {
            PanelLog.failure("blackout: the recovery marker could not be saved — \(error.localizedDescription)")
            message = "Panel blackout could not save its recovery marker (\(error.localizedDescription)). Nothing was changed."
            panelVirtualDisplay = nil
            return
        }

        // Started before the mutation, not after: the failures this covers are a
        // crash and a hang, and the most likely place for either is the call
        // below. A refusal here is final — see startPanelWatchdog for why this
        // stopped being a warning.
        guard startPanelHeartbeat() else {
            rollBackBlackoutAttempt()
            message = "Panel blackout could not create its heartbeat file, so its recovery watchdog would fire immediately. Nothing was changed."
            return
        }
        guard await startPanelWatchdog() else {
            rollBackBlackoutAttempt()
            return
        }

        // Re-checked against the live process immediately before the mutation, not
        // only at startup. The watchdog can die inside the gap, and its own
        // termination handler is no help here: it defers while an operation is in
        // flight, and this IS that operation. Without this the handler fired, the
        // deferred restore refused because the controller was busy, and the very
        // next line took the panel down with nothing left to bring it back.
        // Positive confirmation required here: nothing has been changed yet, so
        // refusing on doubt costs a lit screen behind a shut lid and no more.
        guard panelWatchdog?.isRunning == true, panelCarrierState == .alive else {
            rollBackBlackoutAttempt()
            message = "Panel blackout's recovery layer could not be confirmed before the panel was switched off, so nothing was changed — without it a crash would leave the screen dark with no way back."
            return
        }

        panelBuiltinID = confirmedBuiltin
        panelHeldMode = .virtualDisplay
        let accepted: Bool = DisplayAPI.setDisplayEnabled(
            confirmedBuiltin, false, option: .forAppOnly
        )
        let gone: Bool = await DisplayAPI.waitForActive(
            confirmedBuiltin, active: false, timeout: Self.panelDisableWaitTimeout
        )
        PanelLog.event(
            "blackout: disable(builtin=\(confirmedBuiltin), forAppOnly)"
                + " accepted=\(accepted) gone=\(gone) carrier=\(virtual.displayID)"
        )
        guard accepted || gone else {
            PanelLog.failure("blackout: the built-in refused to switch off — rolled back")
            panelBuiltinID = nil
            panelHeldMode = nil
            rollBackBlackoutAttempt()
            message = "The built-in display refused to switch off; nothing was left changed."
            return
        }
        // Cleared HERE, not before the mutation. Holding the panel again supersedes
        // an earlier restore nobody could confirm — but only once it is actually
        // held. Clearing it a few lines earlier meant a refused disable rolled
        // back with the flag already false, and `rollBackBlackoutAttempt` reads
        // that flag to decide whose watchdog and marker these are: it then tore
        // down the ones it had inherited, leaving a possibly-dark panel with no
        // way back and nothing that would try again.
        panelRestoreUnconfirmed = false
        // Checked once more, now that the panel is actually off. The guard before
        // the mutation narrows the race but cannot close it — a process can die in
        // the microseconds between a liveness read and the call after it — so this
        // is the half that makes the window survivable rather than merely narrow.
        // `performRestorePanel` directly, not `restorePanel`: this is already
        // inside the operation holding the lock, and the wrapper would refuse on
        // `busy` — which is exactly how the first version of this fix let the
        // panel stay off with nothing watching it.
        notePanelCarrierState()
        guard panelWatchdog?.isRunning == true, !panelCarrierPresumedGone else {
            PanelLog.failure(
                "blackout: the recovery layer went away after the panel was switched off"
                    + " — restoring immediately"
            )
            await performRestorePanel(reason: "because its recovery layer went away")
            return
        }
        updateDisplaySleepAssertion()
        PanelLog.event("blackout: armed — \(panelStateLine)")

        // Only now, with the panel confirmed off: this timer's whole job is to
        // notice the lid opening again, and there is nothing to notice until the
        // blackout has actually taken.
        startPanelLidWatch()
        panelAttempts = 0
        readPanelPresentation()
    }

    /// `PanelMode.dim`: take the brightness down and leave the display alone.
    ///
    ///   1 decide            3 heartbeat + watchdog
    ///   2 write the marker  4 brightness down, then read it back
    ///
    /// The same shape as `performBlackout` minus the display work, and
    /// deliberately still under the marker, the heartbeat and the watchdog. Those
    /// exist for a smaller failure here — a dim screen rather than an absent one —
    /// but not for none: `panelDimLevel` persists across a reboot, so an app that
    /// dies mid-dim leaves a panel its owner has no reason to connect to Lidless.
    /// One shared recovery path is also worth more than the branch saved, because
    /// it is what lets a marker written by either mode be adopted by either mode.
    ///
    /// The read-back at the end is not ceremony. `DisplayServicesSetBrightness`
    /// reports success and does nothing on a display it cannot drive (§2.10 item
    /// 4), so "we asked" and "it happened" are genuinely different claims, and
    /// this is the mode where the write IS the whole feature.
    private func performDim(builtin: UInt32) async {
        let decision: BlackoutDecision = SystemProbe.dimDecision(
            builtinID: builtin,
            builtinActive: DisplayAPI.activeDisplayIDs().map { $0.contains(builtin) },
            canChangeBrightness: DisplayAPI.canChangeBrightness(builtin)
        )
        guard case .proceed(let confirmedBuiltin) = decision else {
            if case .refuse(let reason) = decision {
                PanelLog.failure("dim: refused by the pre-flight decision — \(reason)")
                message = "Panel blackout refused: \(reason)."
            }
            return
        }

        guard let saved: Float = SystemProbe.markerBrightness(
            lastOpenLid: panelOpenLidBrightness,
            currentReading: DisplayAPI.brightness(of: confirmedBuiltin)
        ) else {
            PanelLog.failure("dim: the panel's brightness could not be read — no level to return to")
            message = "Panel blackout could not read the panel's brightness, so it would have no level to bring the screen back to. Nothing was changed."
            return
        }
        // Same rule as `performBlackout`: an inherited marker was written while
        // the panel was known readable and is worth more than a fresh one taken
        // from a panel that may already be dark.
        if SystemProbe.markerInheritDecision(
            restoreUnconfirmed: panelRestoreUnconfirmed,
            savedReadable: readSavedDisplayBrightness() != nil
        ) {
            do {
                try "\(saved)\n".write(toFile: displayFile, atomically: true, encoding: .utf8)
            } catch {
                message = "Panel blackout could not save the panel's brightness (\(error.localizedDescription)). Nothing was changed."
                return
            }
        }

        guard startPanelHeartbeat() else {
            rollBackBlackoutAttempt()
            message = "Panel blackout could not create its heartbeat file, so its recovery watchdog would fire immediately. Nothing was changed."
            return
        }
        guard await startPanelWatchdog() else {
            rollBackBlackoutAttempt()
            return
        }

        // Same re-check as `performBlackout`, and for the same reason: the write
        // below is this mode's whole mutation, and it must not happen with the
        // recovery layer already gone.
        guard panelWatchdog?.isRunning == true else {
            rollBackBlackoutAttempt()
            message = "Panel blackout's recovery watchdog stopped before the panel was dimmed, so nothing was changed — without it a crash would leave the screen dark with no way back."
            return
        }

        _ = DisplayAPI.setBrightness(SystemProbe.panelDimLevel, on: confirmedBuiltin)
        let readBack: Float? = DisplayAPI.brightness(of: confirmedBuiltin)
        // `nil` passes. An unreadable probe is not evidence the write failed, and
        // refusing here would disable the mode outright on any Mac where the
        // private read does not work for the built-in — the same reasoning as
        // `panelPresentation`'s `dim != true`, pointing the other way because the
        // safe direction here is to carry on rather than to stop.
        if let readBack, readBack >= SystemProbe.panelVisibleFloor {
            _ = DisplayAPI.setBrightness(saved, on: confirmedBuiltin)
            // Confirmed readable, so tearing the nets down is allowed here — but
            // the flag has to go with them. Left set (the assignment below is
            // never reached on this path) it made `hasPanelToRestore` true with
            // no marker behind it, and offered a restore of nothing.
            panelRestoreUnconfirmed = false
            stopPanelWatchdog()
            try? FileManager.default.removeItem(atPath: displayFile)
            PanelLog.failure(
                "dim: the brightness write was accepted but the level stayed at \(readBack)"
                    + " (floor \(SystemProbe.panelVisibleFloor)) — nothing left changed"
            )
            message = "The panel's brightness did not go down (it is still \(readBack)); nothing was left changed."
            return
        }

        panelBuiltinID = confirmedBuiltin
        panelHeldMode = .dim
        panelRestoreUnconfirmed = false

        // Same post-mutation re-check as `performBlackout`, for the same reason.
        // Ownership is set first so the restore below has something to act on.
        guard panelWatchdog?.isRunning == true else {
            PanelLog.failure(
                "dim: the recovery watchdog stopped after the panel was dimmed — restoring immediately"
            )
            await performRestorePanel(reason: "because its recovery watchdog stopped")
            return
        }
        PanelLog.event("dim: armed — \(panelStateLine)")

        startPanelLidWatch()
        panelAttempts = 0
        readPanelPresentation()
    }

    /// Mirrors `performBlackout`, in reverse:
    ///
    ///   1 wake the display domain    3 enable the built-in
    ///   2 brightness back            4 confirm, and only then release the virtual display
    ///
    /// Step 2 is kept even though `performBlackout` no longer dims, because it is
    /// not only our own dimming it undoes: it is the same path that recovers a
    /// panel left dark by a crashed older build, by macOS, or by
    /// `lidless-display-rescue`. In the normal case it is now inert twice over —
    /// the built-in is still disabled when the probe runs, so brightness reads as
    /// unreadable and the decision is `.restore(marker)`, and a write to a
    /// disabled display does nothing (§2.10 item 4). The panel comes back at the
    /// user's own level because macOS never lost it, not because this restored
    /// it. Measured 2026-08-02: 0.49997443 before the blackout and the same value
    /// after.
    ///
    /// The wake is not optional. In a sleeping display domain
    /// `CGCompleteDisplayConfiguration` fails with 1014 and blocks for about ten
    /// seconds per attempt — measured. The built-in comes back BEFORE the virtual
    /// display goes away, or there is a window with no display at all.
    ///
    /// Safe to call when nothing is held: it is the same code that adopts a
    /// marker left by a previous run, and the same code every exit path uses.
    private func performRestorePanel(reason: String) async {
        let fileManager: FileManager = FileManager.default
        guard hasPanelToRestore else { return }
        // After the `hasPanelToRestore` guard, not before it: this function is
        // called on every exit path and on adoption, so logging the entry would
        // otherwise record a restore of nothing far more often than a real one.
        PanelLog.event("restore \(reason): starting — \(panelStateLine)")

        guard !shouldDeferPanelRestoreUntilLidOpen else {
            PanelLog.event("restore \(reason): deferred until the lid opens (Intel)")
            message = "The built-in panel will be restored when the lid opens. The virtual display and recovery watchdog are staying active until then."
            return
        }

        // Prefer the live attachment. Intel can hand the same physical panel a
        // different opaque CGDirectDisplayID after a clamshell re-enumeration;
        // using the pre-blackout ID then targets an object WindowServer no longer
        // knows. Fall back to the saved ID only while the panel is absent.
        guard let builtin: UInt32 = DisplayAPI.builtinDisplayID() ?? panelBuiltinID else {
            // Not merely inactive — it cannot be NAMED, having left the active,
            // online and window-server lists alike. Measured 2026-08-01 after a
            // crash with the watchdog removed: `active=[23] ws=[23] builtin=none`.
            // Nothing here can enable a display it cannot identify, and retrying
            // thirty times would achieve exactly nothing. This is the precise
            // state `lidless-display-rescue` exists for — it takes no ID and
            // sweeps blind — so hand it the job rather than growing a second copy
            // of that sweep here.
            PanelLog.failure(
                "restore \(reason): the built-in cannot be named at all — handing over to \(Self.rescueBinaryName)"
            )
            await runRescueTool()
            return
        }

        await wakeDisplays()

        let saved: Float? = readSavedDisplayBrightness()
        switch SystemProbe.panelBrightnessDecision(
            savedValue: saved,
            currentValue: DisplayAPI.brightness(of: builtin)
        ) {
        case .leaveAlone:
            // Measured: macOS restores the user's own brightness within seconds of
            // an app-scoped display config reverting. Writing a value of our own
            // over a good one is a second bug wearing a safety net's clothes.
            break
        case .restore(let value):
            DisplayAPI.setBrightness(value, on: builtin)
        }

        let accepted: Bool = DisplayAPI.setDisplayEnabled(builtin, true, option: .forAppOnly)
        var returned: Bool = await DisplayAPI.waitForActive(
            builtin, active: true, timeout: Self.panelWaitTimeout
        )
        // Both halves, because they answer different questions and the pair is
        // the whole diagnosis when a panel stays dark: `accepted` is whether the
        // window server took the request at all, `returned` whether the display
        // actually came back. The result used to be discarded here.
        PanelLog.event(
            "restore \(reason): enable(builtin=\(builtin), forAppOnly)"
                + " accepted=\(accepted) returned=\(returned)"
        )
        if !returned {
            // `kCGConfigurePermanently` as the second attempt only. It is not
            // reverted when this process dies, so it is the wrong default — but a
            // display that will not come back is worse than a configuration that
            // outlives us. It is NEVER attempted with a live virtual carrier:
            // Intel WindowServer persists VirtDisplayN as a separate active
            // DisplaySet even when the same transaction disables it. Keep the
            // carrier and retry instead; once no carrier exists, permanent enable
            // is safe for inherited/crash recovery.
            if panelVirtualDisplay == nil {
                let permanent: Bool = DisplayAPI.setDisplayEnabled(
                    builtin, true, option: .permanently
                )
                returned = await DisplayAPI.waitForActive(
                    builtin, active: true, timeout: Self.panelWaitTimeout
                )
                PanelLog.event(
                    "restore \(reason): app-scoped enable did not take, retried permanently"
                        + " — accepted=\(permanent) returned=\(returned)"
                )
            }
            if !returned, let carrier = panelVirtualDisplay {
                // Idempotent when the app-scoped carrier never went away, and a
                // useful repair if WindowServer briefly deactivated it during the
                // failed panel attempt.
                DisplayAPI.setDisplayEnabled(carrier.displayID, true, option: .forAppOnly)
                _ = await DisplayAPI.waitForActive(
                    carrier.displayID, active: true, timeout: Self.panelWaitTimeout
                )
            }
        }

        guard returned else {
            PanelLog.failure(
                "restore \(reason): the built-in did not come back — carrier kept, \(panelStateLine)"
            )
            message = "The built-in display did not come back (\(reason)). The virtual display was kept so something is still visible — run \(Self.rescueBinaryName)."
            Shell.notify(
                "Lidless could not put the panel back",
                "The built-in display did not come back. Run \(Self.rescueBinaryName) from the app bundle."
            )
            readPanelPresentation()
            return
        }

        // Back in the display list is not the same as readable, and this is the
        // first moment the difference can be measured: the brightness write above
        // runs while the display is still disabled, where it does nothing (§2.10
        // item 4). `.dim` is the mode that makes this matter — `panelDimLevel`
        // survives a reboot, so clearing the marker over a panel still at 1 %
        // throws away the only record of the level to come back to, and leaves a
        // dark screen nobody has a reason to connect to Lidless.
        let level: Float? = DisplayAPI.brightness(of: builtin)
        if level == nil || level! < SystemProbe.panelVisibleFloor {
            if case .restore(let value) = SystemProbe.panelBrightnessDecision(
                savedValue: saved,
                currentValue: level
            ) {
                _ = DisplayAPI.setBrightness(value, on: builtin)
            }
        }
        // Confirmed readable, or the marker stays. An unreadable level is NOT
        // accepted here, unlike `performDim`'s read-back and unlike
        // `panelPresentation` — those two are deciding what to display, and being
        // wrong costs a label. This one decides whether to throw away the only
        // record of the level to come back to, and being wrong costs the screen.
        //
        // It cannot strand a Mac whose brightness getter never works, either: both
        // modes need a readable level to write the marker before they touch
        // anything, so such a Mac can never start a blackout to be stranded by.
        // Bound once and reused by both the guard and the failure log below. The
        // log used to re-read the brightness in the failure branch, which reports
        // a DIFFERENT moment's value than the one that failed the test — the last
        // thing a diagnostic may do is describe a decision it did not witness.
        let confirmedLevel: Float? = DisplayAPI.brightness(of: builtin)
        guard let confirmed: Float = confirmedLevel,
              confirmed >= SystemProbe.panelVisibleFloor else {
            // Intel can publish a new built-in ID as active before the framebuffer
            // is attached to it. In the 2026-08-03 reproduction system_profiler
            // listed no display at all and brightness was unreadable, even though
            // CGGetActiveDisplayList already contained the alleged built-in. The
            // old branch destroyed the carrier here; WindowServer then had no real
            // framebuffer and the screen disappeared until it was restarted.
            //
            // Keep ownership, marker, heartbeat and watchdog. The permanent
            // fallback above may have disabled the carrier atomically, so put it
            // back app-scoped before returning. A later reconcile can retry the
            // panel without ever passing through a topology with no usable screen.
            if let carrier = panelVirtualDisplay {
                DisplayAPI.setDisplayEnabled(carrier.displayID, true, option: .forAppOnly)
                _ = await DisplayAPI.waitForActive(
                    carrier.displayID, active: true, timeout: Self.panelWaitTimeout
                )
            }
            panelRestoreUnconfirmed = true
            PanelLog.failure(
                "restore \(reason): the panel is active but its brightness could not be confirmed"
                    + " (read \(confirmedLevel.map(String.init(describing:)) ?? "unreadable")"
                    + ", floor \(SystemProbe.panelVisibleFloor)) — recovery layer kept"
            )
            message = "Intel reported the panel as active, but its framebuffer and brightness could not be confirmed after \(reason). The virtual display and recovery layer were kept — press Restore panel again."
            Shell.notify(
                "Lidless kept the recovery display",
                "The Intel panel was reported active before its framebuffer was ready. Press Restore panel again."
            )
            readPanelPresentation()
            return
        }
        panelRestoreUnconfirmed = false
        PanelLog.event(
            "restore \(reason): the panel is back and confirmed readable at \(confirmed)"
        )

        panelVirtualDisplay = nil
        panelBuiltinID = nil
        panelHeldMode = nil
        // After ownership is cleared, so the declarative check sees "not needed".
        updateDisplaySleepAssertion()
        stopPanelWatchdog()
        var markerCleared = true
        do {
            if fileManager.fileExists(atPath: displayFile) {
                try fileManager.removeItem(atPath: displayFile)
            }
        } catch {
            markerCleared = false
            appendMessage(
                "The panel is back, but its saved brightness restore point could not be removed: "
                    + error.localizedDescription
            )
        }
        // The counter is only forgiven on a restore that actually finished. A
        // marker that refuses to delete keeps `hasPanelToRestore` true, so
        // reconcile restores again — succeeds again — and resetting here handed it
        // a fresh budget every time. Leaving the count alone lets the cap stop it,
        // which is the difference between a loop that ends and one that does not.
        if SystemProbe.attemptForgivenessDecision(markerStillPresent: !markerCleared) {
            panelAttempts = 0
        }
        readPanelPresentation()
    }

    /// The window server took the virtual display away by itself. That leaves the
    /// built-in disabled with nothing carrying the session — a black screen — so
    /// this is the one place that reacts immediately instead of waiting for the
    /// next reconcile.
    private func panelVirtualDisplayVanished(id: UInt32) {
        // Identity, not just presence. A blackout that failed and was retried
        // leaves the previous display's callback still in flight; without this it
        // arrived late, found the NEW reference and cleared it, tearing down a
        // session that was working. Same rule as the watchdog's termination
        // handler, and it was missing here for the same reason: the callback
        // predates there being two of anything.
        guard panelVirtualDisplay?.displayID == id else { return }
        panelVirtualDisplay = nil
        appendMessage("The virtual display was taken away by macOS; putting the panel back.")
        // Busy means an operation is already mid-flight and will reconcile at its
        // end; the marker on disk is what tells it there is still work to do.
        guard !busy else { return }
        restorePanel(automatic: true)
    }

    /// One supervised sweep, taken when this app has exhausted its own attempts.
    /// Separate from `runRescueTool`'s other callers only in that it reserves the
    /// controller first — reconcile is not holding it here, and a bare call would
    /// race the next tick.
    private func escalateToRescueTool() async {
        guard !busy else { return }
        beginAction(clearMessage: false)
        await runRescueTool()
        finishAction()
    }

    /// Runs the bundled recovery binary to completion and adopts whatever it
    /// achieved. Used when the built-in cannot be identified, which is the one
    /// situation this controller cannot act on and that tool can.
    ///
    /// It removes the marker itself on confirmed success, so success is read back
    /// from the display lists afterwards rather than from its exit status — the
    /// same rule this project applies to `pmset`.
    private func runRescueTool() async {
        guard let tool: URL = Bundle.main.url(forAuxiliaryExecutable: Self.rescueBinaryName),
              FileManager.default.isExecutableFile(atPath: tool.path) else {
            message = "The built-in display could not be found and \(Self.rescueBinaryName) is missing from the app bundle. Rebuild Lidless, or open the lid."
            // Notified, not only messaged. One caller is the quit path, where the
            // window is about to go away and nobody will ever read `message`.
            Shell.notify(
                "Lidless cannot recover the screen",
                "\(Self.rescueBinaryName) is missing from the app bundle. Rebuild Lidless, or open the lid."
            )
            return
        }

        // Run and poll rather than `Shell.run`, which blocks on
        // `readDataToEndOfFile()` and `waitUntilExit()` with no deadline. The
        // rescue sweep makes 32 display-configuration calls, and one of those is
        // documented as able to block for around ten seconds (docs/ARCHITECTURE.md) — so an
        // unbounded wait here can hold the app in `.terminateLater` indefinitely,
        // which is its own way of leaving somebody stuck. Terminating it early is
        // safe: every step it takes only ever makes a display appear, so a partial
        // sweep is a smaller version of the same thing, never a broken one.
        let process = Process()
        process.executableURL = tool
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            message = "The built-in display could not be found and \(Self.rescueBinaryName) would not start (\(error.localizedDescription))."
            Shell.notify(
                "Lidless cannot recover the screen",
                "\(Self.rescueBinaryName) would not start. Open the lid, or run it from the app bundle."
            )
            return
        }
        var waited: TimeInterval = 0
        while process.isRunning, waited < Self.rescueToolTimeout {
            try? await Task.sleep(nanoseconds: Self.rescueToolPollNanoseconds)
            waited += Double(Self.rescueToolPollNanoseconds) / 1_000_000_000
        }
        if process.isRunning {
            // SIGTERM, then SIGKILL if it is ignored. `terminate()` alone returns
            // immediately and proves nothing, so the old "was stopped" message
            // could be simply untrue and a wedged sweep could outlive the app.
            process.terminate()
            var grace: TimeInterval = 0
            while process.isRunning, grace < Self.rescueToolKillGrace {
                try? await Task.sleep(nanoseconds: Self.rescueToolPollNanoseconds)
                grace += Double(Self.rescueToolPollNanoseconds) / 1_000_000_000
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                var reaped: TimeInterval = 0
                while process.isRunning, reaped < Self.rescueToolKillGrace {
                    try? await Task.sleep(nanoseconds: Self.rescueToolPollNanoseconds)
                    reaped += Double(Self.rescueToolPollNanoseconds) / 1_000_000_000
                }
            }
            // Reported as what actually happened. The old wording announced a stop
            // it had not confirmed, which is the same class of claim this whole
            // review has been removing from the display paths.
            appendMessage(process.isRunning
                ? "\(Self.rescueBinaryName) did not stop after \(Int(Self.rescueToolTimeout))s and is still running."
                : "\(Self.rescueBinaryName) was still running after \(Int(Self.rescueToolTimeout))s and was stopped.")
        }

        // The same strict claim `DisplayRescue.builtinIsBack()` makes before it
        // deletes the marker. This used to accept "in the active list" alone,
        // which meant the tool could keep the restore point while the app threw
        // away the ownership and watchdog that would have used it — and at quit
        // there was nobody left to notice.
        let recovered: Bool = DisplayAPI.builtinDisplayID().map { builtin in
            let active: Bool = DisplayAPI.activeDisplayIDs()?.contains(builtin) ?? false
            let readable: Bool = DisplayAPI.brightness(of: builtin)
                .map { $0 >= SystemProbe.panelVisibleFloor } ?? false
            return active && readable
        } ?? false
        if recovered {
            panelVirtualDisplay = nil
            panelBuiltinID = nil
            panelHeldMode = nil
            panelRestoreUnconfirmed = false
            stopPanelWatchdog()
            // Same rule as `performRestorePanel`: the budget is forgiven only when
            // the marker is actually gone. The tool removes it itself on success,
            // but a removal that failed would otherwise hand out a fresh set of
            // attempts on every pass and keep an unstable built-in cycling forever.
            if SystemProbe.attemptForgivenessDecision(
                markerStillPresent: FileManager.default.fileExists(atPath: displayFile)
            ) {
                panelAttempts = 0
            }
            appendMessage("The built-in display had to be recovered by \(Self.rescueBinaryName), and is back.")
        } else {
            message = "The built-in display could not be found or recovered. Open the lid, or from another machine: sudo killall -HUP WindowServer."
            Shell.notify(
                "Lidless could not recover the screen",
                "Open the lid. If that does not help, run \(Self.rescueBinaryName) from the app bundle."
            )
        }
        readPanelPresentation()
    }

    /// `caffeinate -u` is the documented way to declare user activity without
    /// synthesising HID events. Run off the main actor because it is a subprocess
    /// that lives for a second — the display calls it exists to unblock are the
    /// part that has to stay on the main actor.
    private func wakeDisplays() async {
        await Task.detached(priority: .userInitiated) {
            _ = Shell.run(Shell.Command("/usr/bin/caffeinate", ["-u", "-t", "1"]))
        }.value
        try? await Task<Never, Never>.sleep(nanoseconds: Self.panelWakeSettleNanoseconds)
    }

    /// Watches the lid for as long as the panel is held down, and only then.
    ///
    /// Measured 2026-08-01, and the reason this exists: the blackout applied
    /// **eight seconds** after the lid closed with the app's window shut, but
    /// opening the lid again left the screen dark for at least 46 seconds until
    /// it was forced back by hand. The asymmetry is not a tuning problem, it is
    /// structural — `didChangeScreenParametersNotification` fires on the way IN
    /// because macOS is still managing an enabled panel and dims it for the lid
    /// close, and does NOT fire on the way OUT because by then the built-in has
    /// been removed from the display configuration and opening the lid changes
    /// nothing macOS is tracking. So the one event source this feature had was
    /// the one that only works in the dangerous direction, leaving the 60-second
    /// heartbeat to give the screen back.
    ///
    /// One `ioreg` call a second, running only while a blackout is actually held,
    /// is a cheap price for not asking someone to sit in front of a dark screen
    /// for up to a minute. It reads the lid and nothing else; the full probe only
    /// runs when the answer changes.
    /// Advances the `.unknown` clock. Called from the full refresh and from the
    /// one-second lid watch, because the refresh alone does not honour the grace
    /// period it is measuring: with the window closed the background refresh is a
    /// minute apart, so a thirty-second grace became closer to two minutes — and
    /// the whole point of it is a Mac nobody is looking at.
    private func notePanelCarrierState() {
        let state: CarrierState = panelCarrierState
        panelCarrierSnapshot = state
        if state == .unknown {
            if panelCarrierUnknownSince == nil { panelCarrierUnknownSince = .now }
        } else {
            panelCarrierUnknownSince = nil
        }
    }

    /// Records a lid-watch tick, but only when it says something the previous one
    /// did not. See `lastLidWatchNote` for why the filter is not optional.
    ///
    /// The comparison is against the last note REGARDLESS of how long ago it was,
    /// so a watch that ticks unchanged for ten minutes writes one line and a
    /// watch that has stopped ticking altogether writes none. Those two look the
    /// same here on purpose: the periodic state line in the heartbeat is what
    /// separates them, because it comes from a different timer.
    private func noteLidWatch(_ text: String) {
        guard text != lastLidWatchNote else { return }
        lastLidWatchNote = text
        PanelLog.event("lid watch: \(text)")
    }

    private func startPanelLidWatch() {
        panelLidWatch?.invalidate()
        panelLidWatch = Timer.scheduledTimer(
            withTimeInterval: Self.panelLidWatchInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                // `panelOwnedByThisApp`, not `panelVirtualDisplay != nil`: this
                // timer was switched off entirely in `.dim`, so opening the lid
                // left the panel at its minimum until the next sixty-second
                // refresh — with the window closed, up to a minute of dark screen
                // that the README promises comes back at once.
                guard let self, self.panelOwnedByThisApp else { return }
                // Split out of the guard above only so the skip can be recorded.
                // A tick lost to `busy` is the shape of failure this instrument
                // exists for: the panel is held, the lid may already be open, and
                // the one timer that would notice declines to look.
                guard !self.busy else {
                    self.noteLidWatch("skipped — an operation is in flight")
                    return
                }
                // Serviced at one second, not sixty. If the carrier has been
                // unreadable long enough to be presumed gone, that is worth a full
                // refresh immediately rather than at the next background tick.
                self.notePanelCarrierState()
                if self.panelCarrierPresumedGone {
                    self.noteLidWatch("carrier presumed gone — forcing a refresh")
                    self.refresh()
                    return
                }
                guard !self.panelLidProbeInFlight else {
                    self.noteLidWatch("skipped — the previous lid probe has not returned")
                    return
                }
                self.panelLidProbeInFlight = true
                defer { self.panelLidProbeInFlight = false }
                // `!= true` covers unreadable as well as open: an unreadable lid
                // must resolve towards giving the screen back, the same rule
                // reconcilePanelBlackout applies.
                let closed: Bool? = await self.readLidClosed()
                self.noteLidWatch("lid closed=\(closed.map(String.init(describing:)) ?? "unreadable")")
                guard closed != true else { return }
                self.refresh()
            }
        }
        // `.common`, for the same reason the heartbeat needed it: a plain `Timer`
        // stops firing while a menu is tracking, and this one now services the
        // thirty-second carrier clock. Fixing that on the heartbeat and not here
        // left the same hole one timer along.
        if let panelLidWatch {
            RunLoop.main.add(panelLidWatch, forMode: .common)
        }
    }

    /// Back to `Shell`, which is bounded now — and bounded in the one place that
    /// covers every probe rather than this one. A hand-rolled deadline here fixed
    /// the fast lid probe and left the full refresh unbounded, so a hung `ioreg`
    /// still wedged `refreshInFlight` and the panel still missed the lid opening;
    /// it also read its pipe only after the process exited, which deadlocks on
    /// output larger than the buffer.
    /// D3a (`docs/ARCHITECTURE.md`): the two halves are timed
    /// separately because they accuse different culprits, and the log could not
    /// tell them apart.
    ///
    /// `waited` is how long the detached task sat before it began — scheduling.
    /// `ran` is how long `ioreg` actually took. On 2026-08-04 this probe
    /// repeatedly failed to return inside a second while the same `ioreg`,
    /// timed by hand, came back in 53–56 ms every time; the guess was QoS
    /// throttling of a `.utility` task in a background app on an idle Mac, and a
    /// guess is all it was. These two numbers settle it: a large `waited` with a
    /// small `ran` is starvation, the reverse is a genuinely slow call.
    ///
    /// Logged only past a threshold, so a healthy probe stays silent — this
    /// fires once a second for as long as a blackout is held.
    private func readLidClosed() async -> Bool? {
        let queued: ContinuousClock.Instant = .now
        let outcome: (
            value: Bool?, waited: Duration, ran: Duration, status: Int32, detail: Shell.RunDetail
        ) =
            await Task.detached(priority: .utility) {
                let began: ContinuousClock.Instant = .now
                let waited: Duration = queued.duration(to: began)
                let result = Shell.runDetailed(Shell.Command(
                    "/usr/sbin/ioreg",
                    ["-r", "-k", "AppleClamshellState"]
                ))
                let ran: Duration = began.duration(to: .now)
                guard result.status == 0, result.output.contains("AppleClamshellState") else {
                    return (nil, waited, ran, result.status, result.detail)
                }
                return (
                    SystemProbe.clamshellClosed(in: result.output),
                    waited, ran, result.status, result.detail
                )
            }.value
        if outcome.waited + outcome.ran >= Self.lidProbeSlowThreshold {
            // `detail` is the whole point of this line now. Every stall so far
            // reports `status=-1` and `ran` pinned to 24 s, which is the drain
            // deadline rather than the timeout — and `status=-1` is returned by
            // three different conditions, so the number on its own cannot say
            // whether a child hung or whether nothing was ever waiting on one.
            // Recorded prediction (`docs/ARCHITECTURE.md`):
            // `timedOut=false exited=true drained=false`. A `timedOut=true`
            // kills the drain explanation outright.
            PanelLog.failure(
                "lid probe slow: waited=\(outcome.waited) ran=\(outcome.ran)"
                    + " status=\(outcome.status) \(outcome.detail.summary) result="
                    + (outcome.value.map(String.init(describing:)) ?? "unreadable")
            )
        }
        return outcome.value
    }

    /// Returns whether the heartbeat is actually running. The file used to be
    /// created and the result thrown away, which is the one failure the watchdog
    /// cannot tell from a hang: a missing heartbeat reads as infinitely stale, so
    /// a blackout started without one would be undone within seconds, over and
    /// over, by its own safety net.
    /// Everything the blackout is currently holding, on one line.
    ///
    /// Deliberately reports OBSERVED things next to believed ones — `watchdog` is
    /// the live process, `carrierState` the last probe, `lidClosed` the last full
    /// refresh — because the two disagreeing is the interesting case and a line
    /// that only carried our own bookkeeping could never show it.
    private var panelStateLine: String {
        let held: String = panelHeldMode?.rawValue ?? "none"
        let builtin: String = panelBuiltinID.map(String.init) ?? "none"
        let carrier: String = panelVirtualDisplay.map { String($0.displayID) } ?? "none"
        return "state: held=\(held) builtin=\(builtin) carrier=\(carrier)"
            + " carrierState=\(panelCarrierSnapshot) watchdog=\(panelWatchdog?.isRunning == true)"
            + " busy=\(busy) goal=\(panelGoal) attempts=\(panelAttempts)"
            + " lidClosed=\(state.lidClosed) restoreUnconfirmed=\(panelRestoreUnconfirmed)"
            + " displayAsleep=\(displayDomainAsleep)"
    }

    private func startPanelHeartbeat() -> Bool {
        let path: String = displayHeartbeatFile
        guard FileManager.default.createFile(atPath: path, contents: nil) else { return false }
        panelHeartbeat?.cancel()

        // A `DispatchSourceTimer` on a background queue, NOT a `Timer` on the
        // main run loop.
        //
        // This used to be a main-run-loop `Timer` in `.common` mode, and the
        // comment here defended that choice against menu tracking — which
        // `.common` does cover. It does not cover the case that actually
        // happens: a BLOCKED main thread runs no run loop in any mode. Ten
        // main-actor call sites can park for a full `Shell.defaultTimeout` (20 s,
        // and ~21 s counting the SIGTERM-then-SIGKILL tail), and one of them,
        // the authorization dialog, has no timeout at all. Every one of them
        // holds the interprocess lock while it waits. With the heartbeat on that
        // same thread, its file stopped being touched for exactly as long, the
        // rescue watchdog read the staleness as a hung owner and swept displays
        // back underneath a live blackout — the nominal margin was 3 s and the
        // real one was negative.
        //
        // Only the touch is moved. The state line still hops to the main actor,
        // because that is where the state it prints lives; a blocked main thread
        // delays the log line and no longer delays the deadline.
        let timer = DispatchSource.makeTimerSource(queue: Self.panelHeartbeatQueue)
        timer.schedule(
            deadline: .now() + Self.panelHeartbeatInterval,
            repeating: Self.panelHeartbeatInterval,
            leeway: .milliseconds(250)
        )
        timer.setEventHandler { [weak self] in
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: path
            )
            // A state line every five seconds, and only while the panel is held:
            // this timer exists for exactly the duration of a blackout, so the
            // log gets a pulse across the window that can fail and nothing at all
            // the rest of the time. It is also the only line that proves the
            // app's timers are still running — which is what separates "the lid
            // watch looked and saw nothing" from "the lid watch stopped".
            Task { @MainActor in
                guard let self else { return }
                PanelLog.event(self.panelStateLine)
            }
        }
        panelHeartbeat = timer
        timer.resume()
        return true
    }

    /// The way back from a crash OR a hang, and blackout does not proceed without
    /// it. Returns whether it is running.
    ///
    /// This used to be a warning rather than a refusal, on the grounds that the
    /// window server reverting `kCGConfigureForAppOnly` on process death already
    /// covered an outright crash and only the hung case needed cover. **That
    /// revert does not happen** — isolated and disproved on 2026-08-01 by killing
    /// this watchdog first and then the owner, after which the built-in stayed
    /// gone for 57 seconds (see `DisplayAPI.setDisplayEnabled`). With that layer
    /// removed, a blackout started without this watchdog is a blackout with no
    /// automatic way back at all: a crash would leave a dark screen until somebody
    /// who cannot see it runs `lidless-display-rescue` by hand.
    ///
    /// So the trade reversed. Refusing to switch the panel off costs the user a
    /// lit screen behind a closed lid, which is the inconvenience this whole
    /// feature exists to remove; starting anyway costs them the Mac.
    /// `async` for the readiness pause below. Both callers already run inside the
    /// blackout `Task`, and both call this before touching the display.
    private func startPanelWatchdog() async -> Bool {
        guard panelWatchdog == nil else { return true }
        guard let tool: URL = Bundle.main.url(forAuxiliaryExecutable: Self.rescueBinaryName),
              FileManager.default.isExecutableFile(atPath: tool.path) else {
            message = "Panel blackout needs \(Self.rescueBinaryName), which is missing from the app bundle — without it a crash would leave the screen dark with no way back. Rebuild Lidless."
            return false
        }
        // Cleared first, and the clearing is verified: a leftover from a previous
        // watchdog would satisfy the wait below instantly and prove nothing at
        // all. `try?` on its own was not enough — a removal that quietly failed
        // left the handshake answering for a process that no longer exists.
        let readyPath: String = displayHeartbeatFile + SystemProbe.displayWatchdogReadySuffix
        try? FileManager.default.removeItem(atPath: readyPath)
        guard !FileManager.default.fileExists(atPath: readyPath) else {
            message = "Panel blackout could not clear a stale watchdog handshake file at \(readyPath), so it cannot tell a running watchdog from a finished one. Nothing was changed."
            return false
        }

        let process = Process()
        process.executableURL = tool
        process.arguments = ["--watch", String(getpid()), displayHeartbeatFile]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Set before `run()`, or a process that exits immediately can finish
        // before the handler is attached. It is deliberately a no-op until
        // `panelWatchdog` points at this same process — during the readiness wait
        // below there is nothing to put back yet, and `stopPanelWatchdog` clears
        // the reference before terminating so an orderly shutdown does not look
        // like a death.
        //
        // This is the fast path, not the guarantee. `restorePanel` refuses while
        // an operation is in flight, so two other checks carry the case it drops:
        // `performBlackout`/`performDim` re-read the watchdog immediately before
        // their mutation, and `reconcilePanelBlackout` treats "ours, no live
        // watchdog" as not-armed on every tick.
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                guard let self, self.panelWatchdog === finished else { return }
                self.panelWatchdog = nil
                // The heartbeat existed for this process and nothing else reads
                // it. Left running it would keep touching a file with no reader
                // until the next successful restore or quit.
                self.panelHeartbeat?.cancel()
                self.panelHeartbeat = nil
                // Logged before the ownership guard, because a watchdog exiting
                // while nothing is held is the ORDERLY case and its absence from
                // the record would make the two indistinguishable afterwards.
                // The state line reports `watchdog=false` here by construction —
                // the reference was cleared two lines up.
                PanelLog.event(
                    "watchdog: exited with status \(finished.terminationStatus)"
                        + " — \(self.panelStateLine)"
                )
                guard self.panelOwnedByThisApp || self.panelRestoreUnconfirmed else { return }
                PanelLog.failure(
                    "watchdog: it stopped while the panel was still down — restoring now"
                )
                self.appendMessage(
                    "Panel blackout's recovery watchdog stopped while the panel was still down, so there is no longer a way back from a crash. Putting the panel back now."
                )
                self.restorePanel(automatic: true)
            }
        }
        do {
            try process.run()
        } catch {
            PanelLog.failure("watchdog: could not be started — \(error.localizedDescription)")
            message = "Panel blackout's recovery watchdog could not be started (\(error.localizedDescription)), so the panel was left alone — without it a crash would leave the screen dark with no way back."
            return false
        }
        // `run()` returning is not the same claim as "the watchdog is watching",
        // and neither is the process still existing a moment later. A rescue
        // binary that is the wrong architecture, or refuses its arguments, exits
        // within milliseconds and `run()` reports none of it — and the panel would
        // then go dark with the layer that was supposed to bring it back already
        // gone. So the watchdog says so itself: it creates the ready file as the
        // first statement of its watch loop, which is reachable only with
        // arguments it understood. Same rule the rest of the project applies to
        // `pmset` — read the effect back, never trust the call.
        var waited: UInt64 = 0
        while waited < Self.watchdogReadinessTimeoutNanoseconds {
            if FileManager.default.fileExists(atPath: readyPath) { break }
            guard process.isRunning else { break }
            try? await Task.sleep(nanoseconds: Self.watchdogReadinessPollNanoseconds)
            waited += Self.watchdogReadinessPollNanoseconds
        }
        guard FileManager.default.fileExists(atPath: readyPath), process.isRunning else {
            if process.isRunning { process.terminate() }
            PanelLog.failure(
                "watchdog: it never confirmed it was watching (running=\(process.isRunning))"
            )
            message = "Panel blackout's recovery watchdog did not start watching, so the panel was left alone — without it a crash would leave the screen dark with no way back. Rebuild Lidless."
            return false
        }
        panelWatchdog = process
        PanelLog.event("watchdog: watching, pid \(process.processIdentifier)")
        return true
    }

    /// Terminate first, remove the heartbeat afterwards. A missing heartbeat file
    /// reads as infinitely stale, which is a rescue trigger — doing these two in
    /// the other order asks the watchdog to fire on its way out.
    /// Undoes a blackout ATTEMPT without destroying safety nets that predate it.
    ///
    /// An attempt made while `panelRestoreUnconfirmed` is set inherits the marker
    /// and the watchdog from a restore nobody could confirm — they are not this
    /// attempt's to remove. Removing them was the fastest route to the worst state
    /// in this whole feature: a possibly-dark panel with no marker, no watchdog and
    /// `hasPanelToRestore` false, so neither reconcile, nor the termination
    /// handler, nor quit would ever try again. One more unreadable display list
    /// during a retry was enough to reach it.
    private func rollBackBlackoutAttempt() {
        panelVirtualDisplay = nil
        updateDisplaySleepAssertion()
        guard SystemProbe.blackoutRollbackDecision(restoreUnconfirmed: panelRestoreUnconfirmed) else { return }
        stopPanelWatchdog()
        try? FileManager.default.removeItem(atPath: displayFile)
    }

    private func stopPanelWatchdog() {
        panelHeartbeat?.cancel()
        panelHeartbeat = nil
        panelLidWatch?.invalidate()
        panelLidWatch = nil
        if let process: Process = panelWatchdog {
            // Cleared BEFORE terminating, not after: the termination handler treats
            // "still the current watchdog" as an unexpected death and restores the
            // panel. Doing these the other way round makes every orderly shutdown
            // look like the failure the handler exists to catch.
            panelWatchdog = nil
            if process.isRunning { process.terminate() }
        }
        try? FileManager.default.removeItem(atPath: displayHeartbeatFile)
        try? FileManager.default.removeItem(
            atPath: displayHeartbeatFile + SystemProbe.displayWatchdogReadySuffix
        )
    }

    // MARK: Quitting

    /// Whether there is anything left to undo. Checked against the live system
    /// rather than against what this app did, so it also covers a session that
    /// `lidless.sh` started.
    var hasSomethingToRestore: Bool {
        let fileManager = FileManager.default
        // `lidPresentation != .normal`, not `state.lidIgnored` — the latter
        // defaults to false when the probe is unreadable, which used to make
        // the Disable button (and "Quit & disable") unavailable in exactly
        // the situation where pressing it to attempt a fail-safe restore
        // matters most: an uncertain lid state with no other tracked state
        // file. (review round 1.)
        return state.lidPresentation != .normal
            || state.keepAwakeActive
            || fileManager.fileExists(atPath: pidFile)
            || fileManager.fileExists(atPath: lowPowerFile)
            || fileManager.fileExists(atPath: screenLockFile)
            || fileManager.fileExists(atPath: enabledAtFile)
            // A dimmed panel is undone state like any other, and the one kind a
            // person cannot read the window to find out about.
            || hasPanelToRestore
    }

    /// The two auxiliary *settings* only. The panel is deliberately NOT folded in
    /// here, unlike `hasSomethingToRestore` above: this property also drives the
    /// Screen lock card's "your original value is not back yet" state, so a
    /// display restore point would make that card report a screen-lock problem
    /// that does not exist. A stranded panel is reported by the thing that knows
    /// about panels — its own card, in red — and by `hasPanelToRestore` at the
    /// call sites that genuinely mean "anything at all".
    var hasPendingAuxiliaryRestore: Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: lowPowerFile)
            || fileManager.fileExists(atPath: screenLockFile)
    }

    /// Answers `applicationShouldTerminate`.
    ///
    /// Quitting used to leave everything running, deliberately, so that closing
    /// a window could not drop a remote session. With "Disable when quitting"
    /// on, quitting is the same as pressing Disable — which does end the remote
    /// session it was holding open, and on a closed lid means the Mac sleeps.
    /// That is the trade the setting makes.
    ///
    /// Termination is deferred rather than blocked: restoring the lid setting
    /// needs root, and with the sudoers rule absent that raises an authorization
    /// dialog. Quitting still goes ahead if it fails or is cancelled — refusing
    /// to quit would be worse — but the notification says so, and the login-time
    /// watchdog will catch it.
    ///
    /// The built-in panel is put back FIRST and UNCONDITIONALLY, ahead of the
    /// `disableOnQuit` guard. That setting is a choice about whether to leave a
    /// session running — deliberately, so closing up shop over a remote desktop
    /// does not drop the connection. A dark panel is not that kind of state:
    /// nobody opts into quitting the only program that knows how to give their
    /// screen back. That is also why this path returns `.terminateLater` in every
    /// case now, where it used to answer `.terminateNow` outright — the restore
    /// has to be awaited before the process is allowed to go.
    func terminationReply() -> NSApplication.TerminateReply {
        guard !terminationInFlight else { return .terminateLater }
        terminationInFlight = true
        Task { @MainActor in
            // Bounded. `busy` is released by whatever operation holds it, and one
            // of those makes a `CGCompleteDisplayConfiguration` call that this
            // project has no way to put a deadline on — so an unbounded wait here
            // meant a wedged display call could keep the app from ever quitting.
            // Proceeding without the reservation is worse than never quitting only
            // if something else is mid-mutation; after this long, nothing is
            // making progress anyway.
            let quitWaitStarted = ContinuousClock.now
            while busy, quitWaitStarted.duration(to: .now) < .seconds(Self.quitBusyTimeout) {
                try? await Task<Never, Never>.sleep(
                    nanoseconds: Self.operationWaitNanoseconds
                )
            }
            if busy {
                Shell.notify(
                    "Lidless is quitting with an operation still running",
                    "A display call did not return. If the screen is dark, run \(Self.rescueBinaryName)."
                )
            }

            // Reserve the controller before the first suspension. Otherwise a
            // timer refresh could start auto-disable — or a blackout reconcile —
            // during it, and two paths would mutate the same state at once.
            beginAction(clearMessage: false)

            // On Intel, `performRestorePanel` deliberately returns while the lid
            // is closed because its synchronous CoreGraphics enable can wedge.
            // Quitting must not interpret that deferral as success: process exit
            // destroys the virtual display, and the 2026-08-03 incident left both
            // the panel and Touch Bar dark when ControlStrip retained that dead ID.
            // Keep the app, carrier, heartbeat and watchdog alive until opening the
            // lid makes an enable safe. An unreadable lid probe resolves toward a
            // restore attempt, matching every other panel recovery path.
            if shouldDeferPanelRestoreUntilLidOpen {
                setProgressMessage(
                    "Quit is waiting for the lid to open so the built-in panel and Touch Bar can be restored safely."
                )
                Shell.notify(
                    "Lidless is waiting to quit",
                    "Open the lid so the built-in panel and Touch Bar can be restored before the virtual display is removed."
                )
                while panelHeldMode == .virtualDisplay,
                      panelOwnedByThisApp,
                      await readLidClosed() == true {
                    try? await Task<Never, Never>.sleep(
                        nanoseconds: Self.terminationLidPollNanoseconds
                    )
                }
                // The fast probe controls timing; the full snapshot updates the
                // cached lid value checked by `performRestorePanel` below.
                state = await readFreshState()
            }

            // Deliberately outside the cross-process lock taken below. Quitting
            // must not be able to hand the panel back late because a CLI
            // `lidless.sh on` happens to be running — and the CLI cannot touch the
            // panel anyway: a shell command would create the virtual display,
            // disable the panel and then exit, undoing both a millisecond later.
            // See docs/ARCHITECTURE.md
            await performRestorePanel(reason: "quitting")

            // Quitting takes the virtual display with it, so a panel this app
            // could not put back is about to lose the only thing standing in for
            // it — and the watchdog, if it is still there, dies with us too.
            // Escalate to the blind sweep before letting go. That tool takes no
            // display ID and only ever makes displays appear, so running it when
            // nothing is wrong costs a couple of seconds and nothing else.
            if hasPanelToRestore {
                await runRescueTool()
            }

            // Never let process exit tear down the last confirmed carrier. On the
            // 2026-08-03 Intel failure CoreGraphics claimed the built-in was
            // active while system_profiler had no framebuffer for it; rescue
            // correctly kept the marker, but quit proceeded anyway and destroyed
            // the virtual object. Stay alive so the watchdog and a later retry can
            // recover. AppKit will ask again on the user's next Quit.
            if hasPanelToRestore {
                message = "Quit was cancelled because the Intel panel is not yet confirmed readable. The virtual display and recovery watchdog are still active; press Restore panel and try Quit again."
                Shell.notify(
                    "Lidless stayed open to protect the screen",
                    "The built-in panel is not confirmed readable, so the virtual recovery display was kept."
                )
                busy = false
                terminationInFlight = false
                NSApp.reply(toApplicationShouldTerminate: false)
                return
            }

            guard UserDefaults.standard.bool(forKey: Keys.disableOnQuit) else {
                busy = false
                NSApp.reply(toApplicationShouldTerminate: true)
                return
            }

            guard let lockFD = SystemProbe.acquireLock(path: lockFile) else {
                // Another Lidless process is mid-operation — do not fight it
                // for the lid setting. Quitting still proceeds regardless;
                // refusing to quit would be worse, and the watchdog remains
                // the backstop if nothing ends up managing the lid setting.
                // The concurrent operation could itself be an Enable, so this
                // is not a no-op to stay silent about (review round 1).
                Shell.notify(
                    "Lidless still on",
                    "Quitting could not restore the lid setting — another Lidless operation was in progress. Check Status."
                )
                busy = false
                NSApp.reply(toApplicationShouldTerminate: true)
                return
            }
            let initialState = await readFreshState()
            state = initialState
            guard hasSomethingToRestore else {
                SystemProbe.releaseLock(lockFD)
                busy = false
                NSApp.reply(toApplicationShouldTerminate: true)
                return
            }

            await performDisable(
                stopAllCaffeinate: UserDefaults.standard.bool(forKey: Keys.stopAllCaffeinate),
                automatic: true,
                initialState: initialState
            )
            SystemProbe.releaseLock(lockFD)

            let coreSnapshot: SystemState = await readFreshState()
            state = coreSnapshot
            if coreSnapshot.lidPresentation == .normal {
                await restoreScreenLockIfNeeded()
            }

            let snapshot = await readFreshState()
            state = snapshot
            busy = false
            // Same rule as the automatic-shutdown path: an unreadable final probe must not
            // fall through to silence, which used to read as "nothing left to
            // report" — quitting could have left the lid genuinely ignored.
            if snapshot.lidPresentation != .normal {
                Shell.notify("Lidless still on",
                             snapshot.lidPresentation == .unknown
                                ? "Quitting could not verify the lid setting afterward. Run 'sudo pmset -a disablesleep 0' to be sure."
                                : "Quitting could not restore the lid setting. Run 'sudo pmset -a disablesleep 0'.")
            } else if snapshot.keepAwakeActive || hasPendingAuxiliaryRestore
                        || hasPanelToRestore {
                Shell.notify(
                    "Lidless partially restored",
                    "Quitting restored lid sleep, but another setting still needs attention."
                )
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: Actions

    /// Message shown when a concurrent CLI/app operation already holds
    /// lockFile — shared so enable/disable/auto-disable agree on the wording.
    private static let lockUnavailableMessage =
        "Another Lidless process is already enabling/disabling — try again in a moment."

    static let privilegeSetupRequiredMessage =
        "A shutdown limit is set but its one-time permission is not installed, so the limit could never fire. Install the permission, or clear the limit, then try again."

    func enable() {
        guard !busy else { return }
        cancelAutomaticShutdown()
        lastAutomaticShutdownAttempt = nil
        beginAction(clearMessage: true)
        Task { @MainActor in
            // Locked from before the first state read, not just around the
            // mutation below — otherwise two concurrent callers could both
            // observe "no managed caffeinate" before either acquires the lock,
            // and the second would still act on that stale snapshot once it
            // gets its turn. See docs/ARCHITECTURE.md.
            guard let lockFD = SystemProbe.acquireLock(path: lockFile) else {
                message = Self.lockUnavailableMessage
                finishAction()
                return
            }
            let initialState = await readFreshState()
            state = initialState

            // The enforcement point for the privilege rule, not a duplicate of
            // the button's `.disabled`. Both Enable surfaces call straight into
            // here, and one of them used to have no check at all.
            //
            // Checked against `initialState`, deliberately not the `state` this
            // sees on entry: the value flips the moment the installer finishes,
            // and refusing on a snapshot taken before that would block Enable
            // until some later refresh happened to notice.
            if SystemProbe.privilegeSetupBlocksEnable(
                shutdownAfterHours: UserDefaults.standard.integer(forKey: Keys.shutdownAfterHours),
                shutdownBelowBatteryPercent: UserDefaults.standard
                    .integer(forKey: Keys.shutdownBelowBatteryPercent),
                privilegedSupportInstalled: initialState.privilegedSupportInstalled
            ) {
                message = Self.privilegeSetupRequiredMessage
                SystemProbe.releaseLock(lockFD)
                finishAction()
                return
            }

            await performEnable(initialState: initialState)
            SystemProbe.releaseLock(lockFD)

            // Waiting for a human to enter the sysadminctl password must not
            // hold the cross-process lock. Re-read the completed core state
            // first so an optional lock change is never applied after a failed
            // lid/caffeinate enable.
            //
            // That rule was necessary and, on its own, not sufficient. With the
            // lock free for the whole 30-second Terminal wait, a concurrent
            // `lidless.sh off` — which holds this same lock across its entire
            // `off()` — could read the restore point, find the setting still
            // unchanged, "restore" nothing and delete the file, all before
            // `sysadminctl` had applied anything. The relaxed screen lock then
            // survived with no restore point anywhere and nothing reported. So
            // `applyScreenLock` re-takes THIS lock around the two short critical
            // sections — writing the restore point, and consuming it — and
            // leaves only the human wait unlocked.
            let coreState: SystemState = await readFreshState()
            state = coreState
            if coreState.isFullyOn {
                await applyScreenLockIfRequested(defaults: UserDefaults.standard)
            }
            finishAction()
        }
    }

    func disable(stopAllCaffeinate: Bool, automatic: Bool = false) {
        guard !busy else { return }
        if !automatic {
            cancelAutomaticShutdown()
            lastAutomaticShutdownAttempt = nil
        }
        beginAction(clearMessage: !automatic)
        Task { @MainActor in
            guard let lockFD = SystemProbe.acquireLock(path: lockFile) else {
                message = Self.lockUnavailableMessage
                finishAction()
                return
            }
            let initialState = await readFreshState()
            state = initialState
            await performDisable(
                stopAllCaffeinate: stopAllCaffeinate,
                automatic: automatic,
                initialState: initialState
            )
            SystemProbe.releaseLock(lockFD)

            let coreSnapshot: SystemState = await readFreshState()
            state = coreSnapshot
            if coreSnapshot.lidPresentation == .normal {
                await restoreScreenLockIfNeeded()
            }
            finishAction()
        }
    }

    /// Opens the bundled, auditable one-time installer in Terminal. The app
    /// never receives the administrator password; sudo reads it directly.
    func openPrivilegeInstaller() {
        guard let resources: URL = Bundle.main.resourceURL else {
            message = "The app resources directory could not be located."
            return
        }
        let installer: URL = resources.appendingPathComponent(
            "install-auto-shutdown.sh",
            isDirectory: false
        )
        guard FileManager.default.isReadableFile(atPath: installer.path) else {
            message = "The bundled permission installer is missing; rebuild Lidless."
            return
        }

        let quotedPath: String = Shell.shellQuote(installer.path)
        if openInTerminal("/bin/bash \(quotedPath)") {
            message = "Finish the one-time installation in Terminal. Lidless will detect it automatically."
        } else {
            message = "Terminal could not be opened for the one-time installation."
        }
    }

    private func performEnable(initialState: SystemState) async {
        // No early return on an unreadable initial probe (removed — review
        //  round 1 caught the performDisable twin of this bug;
        // the same fail-safe applies here). `initialState.lidIgnored`
        // already defaults to false when unreadable, so the `!lidIgnored`
        // check below already applies `disablesleep 1` for both "confirmed
        // normal" and "unknown" — matching lidless.sh's on(), which attempts
        // the change rather than trusting an unread probe either way.
        let defaults = UserDefaults.standard
        let fileManager = FileManager.default
        // The decision itself is a pure function (SystemProbe.lowPowerEnableDecision,
        // directly unit-tested) — an unreadable Low Power Mode probe used to
        // `return` out of the whole Enable here, aborting caffeinate/the lid
        // setting over a failure in an unrelated optional feature. Skipping
        // just this optional feature and continuing mirrors performDisable's
        // already-correct handling of the same situation a few lines below.
        let hasSavedLowPowerFile = fileManager.fileExists(atPath: lowPowerFile)
        let lowPowerDecision = SystemProbe.lowPowerEnableDecision(
            wantsLowPower: defaults.bool(forKey: Keys.lowPowerWhileActive),
            lowPowerActiveEverywhere: initialState.lowPowerActiveEverywhere,
            powerSettingsReadable: initialState.powerSettingsReadable,
            currentValuesReadable: initialState.lowPowerACReadable && initialState.lowPowerBatteryReadable,
            hasSavedLowPowerFile: hasSavedLowPowerFile,
            savedLowPowerValid: hasSavedLowPowerFile ? readSavedLowPower() != nil : true
        )
        let enableLowPower: Bool
        switch lowPowerDecision {
        case .attempt:
            enableLowPower = true
        case .skip(let message):
            enableLowPower = false
            if let message { appendMessage(message) }
        }

        let sessionWasInactive = !initialState.lidIgnored && !initialState.keepAwakeActive
        var managedPID = initialState.caffeinatePID
        var startedPID: Int32?
        if managedPID == nil {
            // Plain -s is honoured only on AC power; -i adds the assertion that
            // also holds on battery.
            let flags = defaults.bool(forKey: Keys.keepAwakeOnBattery) ? "-si" : "-s"
            guard let pid = await startCaffeinate(flags: flags) else {
                if message == nil { message = "Could not start caffeinate." }
                return
            }
            startedPID = pid
            managedPID = Int(pid)
        }

        if !initialState.lidIgnored {
            let command = Shell.Command("/usr/bin/pmset", ["-a", "disablesleep", "1"])
            let result = Shell.runPrivilegedPreferNonInteractive([command])
            if !result.ok {
                // The initial probe may have been unreadable (lidIgnored
                // defaults to false in that case), so a failed command here
                // does not necessarily mean the persistent setting is
                // actually off — it could already be ignored for real. Re-read
                // before rolling back: blindly stopping the caffeinate we just
                // started, without checking, used to risk leaving an
                // already-ignored lid setting orphaned with nothing keeping
                // the Mac awake. Only a confirmed-normal read justifies giving
                // up and rolling back; an unreadable result keeps caffeinate
                // and the timestamp, same as the unreadable case below. See
                // docs/ARCHITECTURE.md — review round 4.
                let verified: Bool? = await readLiveLidState()
                switch verified {
                case .some(true):
                    break // already ignored despite the failing command — proceed as if it had succeeded
                case .none:
                    ensureEnabledAt(reset: sessionWasInactive)
                    message = "Lid setting was not applied — \(result.output). Its current state could not be verified either; caffeinate was left running for safety."
                    return
                case .some(false):
                    message = "Lid setting was not applied — \(result.output)"
                    await rollBackCaffeinateIfStarted(startedPID)
                    return
                }
            }
        }

        let verifiedLidIgnored: Bool? = await readLiveLidState()
        let verifiedCaffeinate: Bool
        if let managedPID {
            verifiedCaffeinate = await isCaffeinateRunning(pid: managedPID)
        } else {
            verifiedCaffeinate = false
        }

        guard let verifiedLidIgnored else {
            // The persistent setting may already be active. Keep caffeinate and
            // the timestamp instead of creating an untracked orphaned session.
            ensureEnabledAt(reset: sessionWasInactive)
            message = "The lid setting may have changed, but it could not be verified. caffeinate was left running for safety; press Disable."
            return
        }

        guard verifiedLidIgnored else {
            message = "The lid setting did not change."
            await rollBackCaffeinateIfStarted(startedPID)
            return
        }

        // Write the safety timestamp as soon as the persistent lid setting is
        // confirmed. Optional features must never prevent the auto-off guard.
        ensureEnabledAt(reset: sessionWasInactive)

        guard verifiedCaffeinate else {
            // The PID has been re-read and no longer belongs to caffeinate.
            // Keeping it would risk killing an unrelated caffeinate if macOS
            // reused that number before a later managed-only Disable.
            let stalePIDOutcome: String
            do {
                try fileManager.removeItem(atPath: pidFile)
                stalePIDOutcome = "Its stale PID was cleared; the safety timestamp was kept."
            } catch {
                stalePIDOutcome = "Its stale PID file could not be removed: \(error.localizedDescription)"
            }
            message = "Lid sleep is disabled, but caffeinate did not stay running. \(stalePIDOutcome) Press Disable."
            return
        }

        if enableLowPower {
            if !fileManager.fileExists(atPath: lowPowerFile) {
                let previous = "\(initialState.lowPowerAC ? 1 : 0):\(initialState.lowPowerBattery ? 1 : 0)"
                do {
                    try previous.write(toFile: lowPowerFile, atomically: true, encoding: .utf8)
                } catch {
                    appendMessage("Lidless is on, but Low Power Mode was not changed because its previous value could not be saved.")
                    return
                }
            }

            let lowPowerCommand = Shell.Command(
                "/usr/bin/pmset",
                ["-a", "lowpowermode", "1"]
            )
            let lowPowerResult = Shell.runPrivilegedPreferNonInteractive([lowPowerCommand])
            if !lowPowerResult.ok {
                appendMessage("Lidless is on, but Low Power Mode was not applied — \(lowPowerResult.output)")
            }
        }
    }

    private func performDisable(
        stopAllCaffeinate: Bool,
        automatic: Bool,
        initialState: SystemState
    ) async {
        // The panel before even the lid setting. Everything else this function
        // restores can be read about in the window afterwards; a person looking
        // at a dark screen cannot read anything. A no-op when nothing is held,
        // which is how the quit path can already have done it.
        await performRestorePanel(reason: "disabling")

        // Lid next: it is the setting that persists across reboots, so restore
        // it before anything that could fail or be cancelled. An unreadable
        // initial probe must NOT skip the attempt — attempting a restore that
        // turns out to have been unnecessary is a harmless no-op; skipping one
        // that was actually needed is the real danger. Mirrors lidless.sh's
        // off(), which treats "unknown" the same as "ignored" for this
        // purpose (review round 1 caught this Swift/shell mismatch —
        // this used to `return` on an unreadable probe without even trying).
        if initialState.lidPresentation != .normal {
            let command = Shell.Command("/usr/bin/pmset", ["-a", "disablesleep", "0"])
            let result = executePrivileged([command], automatic: automatic)
            guard result.ok else {
                message = "Lid setting NOT restored — \(result.output)"
                return
            }

            let verifiedLidIgnored: Bool? = await readLiveLidState()
            guard verifiedLidIgnored == false else {
                message = verifiedLidIgnored == nil
                    ? "The lid restore command completed, but its result could not be verified. Nothing else was stopped."
                    : "Lid setting NOT restored. Nothing else was stopped."
                return
            }
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: lowPowerFile) {
            if !initialState.powerSettingsReadable {
                appendMessage("Low Power Mode was not restored because current power sources could not be read.")
            } else if let saved = readSavedLowPower() {
                var commands = [Shell.Command(
                    "/usr/bin/pmset",
                    ["-c", "lowpowermode", String(saved.ac)]
                )]
                if initialState.hasBattery {
                    commands.append(Shell.Command(
                        "/usr/bin/pmset",
                        ["-b", "lowpowermode", String(saved.battery)]
                    ))
                }
                let result = executePrivileged(commands, automatic: automatic)
                if result.ok {
                    try? fileManager.removeItem(atPath: lowPowerFile)
                } else {
                    appendMessage("Low Power Mode NOT restored — \(result.output)")
                }
            } else {
                appendMessage("Saved Low Power Mode state is invalid; it was left untouched.")
            }
        }

        let lidBeforeCaffeinateStop: Bool? = await readLiveLidState()
        guard lidBeforeCaffeinateStop == false else {
            message = lidBeforeCaffeinateStop == nil
                ? "Could not verify normal lid sleep before stopping caffeinate."
                : "Lid sleep became disabled again; caffeinate was left running for safety."
            return
        }

        let managedPID = initialState.caffeinatePID
        var caffeinateStopped = true
        if let managedPID {
            caffeinateStopped = await stopCaffeinate(pid: managedPID)
        }

        if stopAllCaffeinate {
            let stopResult: (targeted: [Int], remaining: [Int], enumerationFailed: Bool) =
                await stopAllCaffeinateProcesses()
            if stopResult.enumerationFailed {
                appendMessage("Could not enumerate current caffeinate processes; stop-all could not be completed.")
            }
            if !stopResult.targeted.isEmpty {
                let stoppedPIDs: [Int] = stopResult.targeted.filter { pid in
                    !stopResult.remaining.contains(pid)
                }
                if !stoppedPIDs.isEmpty {
                    appendMessage(
                        "Also stopped other caffeinate processes: "
                            + stoppedPIDs.map(String.init).joined(separator: " ")
                    )
                }
                if !stopResult.remaining.isEmpty {
                    appendMessage(
                        "Could not confirm these caffeinate processes stopped: "
                            + stopResult.remaining.map(String.init).joined(separator: " ")
                    )
                }
            }
            if let managedPID: Int = managedPID {
                caffeinateStopped = !(await isCaffeinateRunning(pid: managedPID))
            }
        }

        if caffeinateStopped {
            try? fileManager.removeItem(atPath: pidFile)
            try? fileManager.removeItem(atPath: enabledAtFile)
        } else {
            appendMessage("caffeinate is still running; its PID and session timestamp were kept for another Disable attempt.")
        }

    }

    private func restoreScreenLockIfNeeded() async {
        let fileManager: FileManager = FileManager.default
        // Restore whenever a saved value exists, even if the option is now off;
        // otherwise the relaxed delay would be stranded forever.
        if fileManager.fileExists(atPath: screenLockFile) {
            if let saved = readSavedScreenLock() {
                await applyScreenLock(to: saved, savingCurrent: false)
            } else {
                appendMessage("Saved screen-lock state is invalid; it was left untouched.")
            }
        }
    }

    private func applyScreenLockIfRequested(defaults: UserDefaults) async {
        guard defaults.bool(forKey: Keys.relaxScreenLock) else { return }
        if defaults.integer(forKey: Keys.shutdownAfterHours) > 0
            || defaults.integer(forKey: Keys.shutdownBelowBatteryPercent) > 0 {
            appendMessage(
                "Screen-lock relaxation was skipped because automatic shutdown cannot restore it without your account password."
            )
            return
        }
        let delay = defaults.integer(forKey: Keys.screenLockDelay)
        await applyScreenLock(
            to: delay == 0 ? "off" : String(delay),
            savingCurrent: true
        )
    }

    private func beginAction(clearMessage: Bool) {
        stateRevision &+= 1
        busy = true
        if clearMessage {
            message = nil
        }
    }

    private func finishAction() {
        busy = false
        refresh()
    }

    private func readFreshState() async -> SystemState {
        let path: String = pidFile
        let privilegedSupportInstalled: Bool = state.privilegedSupportInstalled
        return await Task.detached(priority: .utility) {
            SystemProbe.read(
                pidFile: path,
                privilegedSupportOverride: privilegedSupportInstalled
            )
        }.value
    }

    private func readLiveLidState() async -> Bool? {
        await Task.detached(priority: .utility) {
            SystemProbe.lidIgnored()
        }.value
    }

    private func isCaffeinateRunning(pid: Int) async -> Bool {
        await Task.detached(priority: .utility) {
            SystemProbe.isCaffeinateProcess(pid)
        }.value
    }

    private func stopCaffeinate(pid: Int) async -> Bool {
        let result = Shell.run(Shell.Command("/bin/kill", [String(pid)]))
        if result.status != 0, !(await isCaffeinateRunning(pid: pid)) {
            return true
        }

        for _ in 0..<Self.caffeinateExitPollAttempts {
            if !(await isCaffeinateRunning(pid: pid)) {
                return true
            }
            try? await Task<Never, Never>.sleep(
                nanoseconds: Self.caffeinateExitPollNanoseconds
            )
        }
        return false
    }

    /// Stops all current-user caffeinate processes and verifies them over one
    /// shared polling window. The shared window keeps the worst-case delay at
    /// roughly one second regardless of the number of processes; the temporary
    /// PID arrays are small and exist only during an explicit Disable action.
    private func stopAllCaffeinateProcesses() async -> (
        targeted: [Int],
        remaining: [Int],
        enumerationFailed: Bool
    ) {
        let queryResult: CaffeinatePIDQueryResult = await Task.detached(priority: .utility) {
            SystemProbe.caffeinatePIDQuery()
        }.value
        let targeted: [Int]
        switch queryResult {
        case .found(let pids):
            targeted = pids
        case .none:
            return ([], [], false)
        case .failed:
            return ([], [], true)
        }

        let arguments: [String] = targeted.map(String.init)
        _ = Shell.run(Shell.Command("/bin/kill", arguments))

        var remaining: [Int] = targeted
        for _ in 0..<Self.caffeinateExitPollAttempts {
            var stillRunning: [Int] = []
            stillRunning.reserveCapacity(targeted.count)
            for pid: Int in targeted {
                if await isCaffeinateRunning(pid: pid) {
                    stillRunning.append(pid)
                }
            }
            remaining = stillRunning
            if remaining.isEmpty {
                break
            }
            try? await Task<Never, Never>.sleep(
                nanoseconds: Self.caffeinateExitPollNanoseconds
            )
        }
        return (targeted, remaining, false)
    }

    private func rollBackCaffeinateIfStarted(_ pid: Int32?) async {
        guard let pid else { return }
        if await stopCaffeinate(pid: Int(pid)) {
            try? FileManager.default.removeItem(atPath: pidFile)
        } else {
            appendMessage("The newly started caffeinate process could not be stopped; its PID was kept.")
        }
    }

    private func executePrivileged(
        _ commands: [Shell.Command],
        automatic: Bool
    ) -> (ok: Bool, output: String) {
        if !automatic {
            return Shell.runPrivilegedPreferNonInteractive(commands)
        }

        var outputs: [String] = []
        for command in commands {
            let result = Shell.runPrivilegedQuietly(command)
            if !result.output.isEmpty {
                outputs.append(result.output)
            }
            if !result.ok {
                return (false, outputs.joined(separator: "\n"))
            }
        }
        return (true, outputs.joined(separator: "\n"))
    }

    /// A note about work in progress: same slot, quieter tone. See
    /// `messageIsProgress`.
    private func setProgressMessage(_ text: String) {
        message = text
        messageIsProgress = true
    }

    /// Clears the note slot. The user asked for it to go; nothing else in the
    /// app can decide that for them, because most of what lands here is written
    /// by paths with no user action behind them at all.
    func dismissMessage() {
        message = nil
    }

    private func appendMessage(_ text: String) {
        if let current = message, !current.isEmpty {
            message = current + "\n" + text
        } else {
            message = text
        }
    }

    private func startCaffeinate(flags: String) async -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = [flags]
        do {
            try process.run()
        } catch {
            return nil
        }
        let pid = process.processIdentifier
        do {
            try String(pid).write(toFile: pidFile, atomically: true, encoding: .utf8)
        } catch {
            // Confirmed via stopCaffeinate's own poll-and-re-check, not by
            // process.terminate()'s lack of a return value — the same rule
            // this file already applies to every other stop path, extended
            // here to this cleanup-on-failure path. review round 7
            // caught that this used to claim success unconditionally right
            // after an unverified terminate().
            if await stopCaffeinate(pid: Int(pid)) {
                appendMessage("Could not record the new caffeinate process (pid \(pid)) — stopped it for safety.")
            } else {
                appendMessage("Could not record the new caffeinate process (pid \(pid)), and could not confirm it was stopped — it may still be running untracked.")
            }
            return nil
        }
        return pid
    }

    private func readSavedScreenLock() -> String? {
        guard let text = try? String(contentsOfFile: screenLockFile, encoding: .utf8) else { return nil }
        return SystemProbe.savedScreenLock(in: text)
    }

    /// Saved as "ac:battery", e.g. "0:1".
    private func readSavedLowPower() -> (ac: Int, battery: Int)? {
        guard let text = try? String(contentsOfFile: lowPowerFile, encoding: .utf8) else { return nil }
        return SystemProbe.savedLowPower(in: text)
    }

    private func readEnabledAt() -> Date? {
        guard let text = try? String(contentsOfFile: enabledAtFile, encoding: .utf8) else { return nil }
        return SystemProbe.enabledAt(in: text)
    }

    private func ensureEnabledAt(reset: Bool, now: Date = Date()) {
        if !reset, let existing = readEnabledAt(),
           existing.timeIntervalSince(now) <= Self.enabledAtFutureTolerance {
            return
        }

        let timestamp = String(Int(now.timeIntervalSince1970))
        do {
            try timestamp.write(toFile: enabledAtFile, atomically: true, encoding: .utf8)
        } catch {
            appendMessage("Enabled, but the auto-off start time could not be saved.")
        }
    }

    /// sysadminctl demands the account password and only accepts it from its own
    /// interactive prompt. Send it directly to Terminal so the password goes
    /// straight into sysadminctl, never through this app. A previous root-first
    /// attempt only added a redundant administrator dialog on current macOS.
    ///
    /// Success is decided by re-reading the value, not by the exit status:
    /// sysadminctl exits 0 and writes "Password is required!" to stderr, so both
    /// the status and stdout report success on a command that changed nothing.
    /// Runs `body` while holding the interprocess lock, or returns `nil` if the
    /// lock could not be taken.
    ///
    /// Only for short, synchronous critical sections. `acquireLock` is
    /// non-blocking (`flock(fd, LOCK_EX | LOCK_NB)`, `SystemProbe`) and returns
    /// `nil` for contention and for a failed open alike, so every caller has to
    /// decide what a `nil` means for it — there is no waiting and no retry here.
    ///
    /// Re-entrancy warning: `flock` locks are per open file description, so
    /// taking this while this same process already holds `lockFile` on another
    /// descriptor fails exactly like contention. Every caller must already have
    /// released it.
    private func withInterprocessLock<T>(_ body: () -> T) -> T? {
        guard let descriptor = SystemProbe.acquireLock(path: lockFile) else { return nil }
        defer { SystemProbe.releaseLock(descriptor) }
        return body()
    }

    private func applyScreenLock(to value: String, savingCurrent: Bool) async {
        guard let canonicalValue = SystemProbe.savedScreenLock(in: value) else {
            appendMessage("Invalid screen-lock value was rejected.")
            return
        }

        if savingCurrent {
            // Under the lock. Not for the Terminal wait below — that still runs
            // unlocked, for the reason the enable path gives — but for the write
            // itself, because `lidless.sh off` holds this same lock across the
            // whole of its `off()`, restore point included. Unsynchronised, the
            // CLI could read and delete the restore point in the window between
            // this write and `sysadminctl` actually applying the new value; the
            // relaxed setting then survived with nothing on disk to undo it, and
            // nothing said so. Same lock as the CLI's, deliberately: a private
            // second lock would serialise against nothing.
            let outcome: ScreenLockRestorePointWrite? = withInterprocessLock {
                if FileManager.default.fileExists(atPath: screenLockFile) {
                    return readSavedScreenLock() != nil ? .ready : .invalidSavedValue
                }
                let current = SystemProbe.screenLock()
                guard let canonicalCurrent = SystemProbe.savedScreenLock(in: current) else {
                    return .unknownCurrentValue
                }
                do {
                    try canonicalCurrent.write(
                        toFile: screenLockFile,
                        atomically: true,
                        encoding: .utf8
                    )
                    return .ready
                } catch {
                    return .writeFailed
                }
            }
            switch outcome {
            case .ready:
                break
            case .invalidSavedValue:
                appendMessage("Saved screen-lock state is invalid; the setting was not changed.")
                return
            case .unknownCurrentValue:
                appendMessage("Current screen-lock value is unknown; the setting was not changed.")
                return
            case .writeFailed:
                appendMessage("Could not save the current screen-lock value; the setting was not changed.")
                return
            case nil:
                appendMessage("Another Lidless operation is in progress; the screen-lock setting was not changed. Try again in a moment.")
                return
            }
        }

        // Avoid opening Terminal when the requested value is already active.
        if SystemProbe.screenLock() == canonicalValue {
            finishScreenLockRestorePoint(applied: true, savingCurrent: savingCurrent)
            return
        }

        let completionFile: String = NSTemporaryDirectory()
            + "io.github.lidless.screenlock-"
            + UUID().uuidString
        let command: String = "/usr/sbin/sysadminctl -screenLock \(canonicalValue) -password -; "
            + "/usr/bin/touch \(Shell.shellQuote(completionFile))"

        guard openInTerminal(command) else {
            appendMessage("Terminal could not be opened; the screen-lock setting was not changed.")
            return
        }

        appendMessage("Screen lock needs your account password — finish it in Terminal. Lidless is waiting for the result.")
        let outcome: ScreenLockCommandOutcome = await waitForScreenLock(
            canonicalValue,
            completionFile: completionFile
        )
        try? FileManager.default.removeItem(atPath: completionFile)

        switch outcome {
        case .applied:
            finishScreenLockRestorePoint(applied: true, savingCurrent: savingCurrent)
        case .rejected:
            appendMessage("Screen lock was not changed. The saved restore point was kept.")
        case .timedOut:
            appendMessage("Timed out waiting for the screen-lock command. The saved restore point was kept.")
        }
    }

    /// Deletes the restore point under the same lock that guards writing it, if
    /// `SystemProbe.screenLockRestorePointIsSpent` says it is spent.
    ///
    /// A failure to take the lock is reported and the file is **kept** — see that
    /// function for why the two errors are not symmetric.
    private func finishScreenLockRestorePoint(applied: Bool, savingCurrent: Bool) {
        let acted: Bool? = withInterprocessLock {
            guard SystemProbe.screenLockRestorePointIsSpent(
                commandApplied: applied, savingCurrent: savingCurrent, lockHeld: true
            ) else { return false }
            removeScreenLockRestorePoint()
            return true
        }
        if acted == nil {
            appendMessage("Another Lidless operation is in progress; the screen-lock restore point was kept. It will be used by the next Disable.")
        }
    }

    private func waitForScreenLock(
        _ expectedValue: String,
        completionFile: String
    ) async -> ScreenLockCommandOutcome {
        for _ in 0..<Self.screenLockPollAttempts {
            let observation: (value: String, commandCompleted: Bool) = await Task.detached(
                priority: .utility
            ) {
                let currentValue: String = SystemProbe.screenLock()
                let completed: Bool = FileManager.default.fileExists(atPath: completionFile)
                return (currentValue, completed)
            }.value

            if observation.value == expectedValue {
                return .applied
            }
            if observation.commandCompleted {
                // The Terminal command can apply the value and create its
                // completion marker between the two reads above. Re-read once
                // after observing the marker so that successful commands are
                // not reported as rejected by that narrow race.
                let finalValue: String = await Task.detached(priority: .utility) {
                    SystemProbe.screenLock()
                }.value
                return finalValue == expectedValue ? .applied : .rejected
            }

            try? await Task<Never, Never>.sleep(
                nanoseconds: Self.screenLockPollNanoseconds
            )
        }
        return .timedOut
    }

    private func removeScreenLockRestorePoint() {
        do {
            try FileManager.default.removeItem(atPath: screenLockFile)
        } catch {
            appendMessage(
                "Screen lock was restored, but its saved restore point could not be removed: "
                    + error.localizedDescription
            )
        }
    }

    @discardableResult
    private func openInTerminal(_ command: String) -> Bool {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        var error: NSDictionary?
        guard let script: NSAppleScript = NSAppleScript(source: source) else {
            return false
        }
        script.executeAndReturnError(&error)
        return error == nil
    }

}

// MARK: - Views

/// What a module's colour means. Deliberately five cases and not "one colour per
/// module": the colour reports the state, so a glance at the window answers "is
/// anything wrong" before any label is read.
///
/// - `active`: on, and Lidless is the one holding it.
/// - `idle`: off, and that is the normal resting state.
/// - `auxiliary`: on, but authorised separately — only the screen lock, which
///   needs the account password both ways and cannot use the sudoers rule.
/// - `attention`: needs a decision from the person at the keyboard.
/// - `critical`: the Mac is about to be powered off, the one setting the whole
///   tool exists for is not in place, or the built-in panel is dark with nobody
///   managing it. The third was a deliberate choice over `attention`: `attention`
///   asks someone to decide something, and a stranded panel is not a decision —
///   it is a screen that may be showing nothing at all, which is the worst thing
///   any part of this tool can leave behind.
enum ModuleTone {
    case active
    case idle
    case auxiliary
    case attention
    case critical

    /// What the colour means, in words. `README.md` states outright that
    /// "colour is the state, not the category" — which is precise, and leaves a
    /// window with exactly one modality. VoiceOver reads this instead.
    var spoken: String {
        switch self {
        case .active: return "active"
        case .idle: return "inactive"
        case .auxiliary: return "authorised separately"
        case .attention: return "needs attention"
        case .critical: return "critical"
        }
    }

    var accent: Color {
        switch self {
        case .active: return .green
        case .idle: return .secondary
        case .auxiliary: return .purple
        case .attention: return .orange
        case .critical: return .red
        }
    }

    /// Tinted only where the tone is a call to action; `active` stays neutral so
    /// that a healthy window is calm rather than four saturated green cards.
    var fill: Color {
        switch self {
        case .critical: return .red.opacity(0.09)
        case .attention: return .orange.opacity(0.07)
        default: return .primary.opacity(0.04)
        }
    }

    var border: Color {
        switch self {
        case .idle: return .primary.opacity(0.09)
        default: return accent.opacity(0.4)
        }
    }

    /// Idle rings read as decoration at full strength, which made an off module
    /// look as deliberate as an on one.
    var ringOpacity: Double { self == .idle ? 0.4 : 1 }
}

/// One titled section of the window — the options list, or the shutdown limits.
///
/// Fixed height, like everything else here: the window must not resize as states
/// come and go, so content is top-aligned and a section with less to say leaves
/// the bottom empty rather than shrinking. `trailing` is the section's own status
/// line, right-aligned in the title row.
struct SectionCard<Content: View>: View {
    let symbol: String
    let title: String
    var trailing: String?
    var tone: ModuleTone = .idle
    let height: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tone.accent.opacity(tone.ringOpacity))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tone == .idle ? Color.primary : tone.accent)
                Spacer(minLength: 10)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 11))
                        .foregroundStyle(tone == .idle ? Color.secondary : tone.accent)
                        .lineLimit(1)
                        .help(trailing)
                }
            }
            .frame(height: 18)

            content
        }
        // The content gets the section's full height, not just its own ideal, so
        // a `Spacer` inside it can absorb the difference. Without this the
        // leftover always pooled at the bottom of the card as a blank band.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .background(tone.fill, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(tone.border, lineWidth: 1)
        )
    }
}

/// One reading in the band across the top of the window: what a probe says right
/// now, as icon / name / value / qualifier. These replaced the label-and-value
/// rows that used to sit inside each card — the same numbers, but readable
/// without finding the card that owned them.
///
/// **Every block in that band is one of these, including the overall verdict.**
/// The verdict was briefly its own shape — a ring instead of a rounded square,
/// its text beside the icon rather than under it, and two sizes larger — and the
/// band read as five unrelated things, because every line of text sat at a
/// different height from the one next to it. It is a `prominent` tile now and
/// differs only in width, fill and border.
///
/// Everything is one line and `minimumScaleFactor` is deliberately absent from
/// `detail`: a qualifier that shrinks to fit is a qualifier nobody reads. It
/// truncates instead and carries the full text as a tooltip.
struct StatusTile: View {
    let symbol: String
    let title: String
    let value: String
    let detail: String
    let tone: ModuleTone
    /// The verdict tile. Tinted where the others stay neutral — `ModuleTone`
    /// keeps `active` calm on purpose so a working window is not a wall of green,
    /// and this is the one block where the colour earns it.
    var prominent: Bool = false

    private var fill: Color {
        guard prominent else { return tone.fill }
        return tone == .idle ? .primary.opacity(0.07) : tone.accent.opacity(0.12)
    }

    private var border: Color {
        guard prominent else { return tone.border }
        return tone == .idle ? .primary.opacity(0.16) : tone.accent.opacity(0.5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            RoundedRectangle(cornerRadius: 8)
                .fill(tone.accent.opacity(tone == .idle ? 0.10 : 0.16))
                .overlay(
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(tone.accent.opacity(tone.ringOpacity))
                )
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tone == .idle ? Color.primary : tone.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(detail)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(fill, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(border, lineWidth: 1)
        )
        // One element, not three unrelated fragments of text — and the tone is
        // spoken, because in this window the colour IS the state. Without this
        // the band reads as a list of loose words with the meaning left in the
        // fill colour, which VoiceOver cannot see.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(value), \(detail), \(tone.spoken)")
    }
}

/// One switchable option in the options list: checkbox, glyph, name, and a line
/// saying what it does or what it is currently doing.
///
/// There is deliberately no per-module on/off switch anywhere in this window:
/// Enable and Disable apply `caffeinate` and `pmset disablesleep` together in one
/// authorised step, so a switch that claimed to run half of that would promise
/// control the app cannot deliver. Every checkbox here arms a standing rule
/// instead, and takes effect on the next Enable. Panel blackout is no exception —
/// ticking it blacks nothing out on its own.
///
/// A row that needs a second control (a mode, a delay) puts it at the trailing
/// edge of its own line rather than under it. That keeps the row's height the
/// same whether the control is showing or not, which is what stops the window
/// from resizing when an option is ticked.
struct OptionRow<Accessory: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    /// Either a fixed explanation of the option or, for the two rows whose state
    /// has nowhere else to live, that state. One line, and written to fit.
    let subtitle: String
    @Binding var isOn: Bool
    var enabled: Bool = true
    var hint: String = ""
    /// Width reserved for the trailing control. Constant per row and never
    /// derived from `isOn`: a width that changed with the checkbox would move the
    /// text beside it every time someone ticked something.
    var accessoryWidth: CGFloat = 0
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(!enabled)

            RoundedRectangle(cornerRadius: 7)
                .fill(tint.opacity(0.16))
                .overlay(
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(tint)
                )
                .frame(width: 28, height: 28)

            // `maxWidth: .infinity`, not a `Spacer` between this and the
            // accessory: a spacer is flexible and SwiftUI hands it a share of the
            // slack rather than only its minimum, so the title lost around 20 pt
            // it could have used and truncated to "Darken the built-in scre…"
            // while empty space sat beside it. Claiming the leftover here instead
            // leaves the spacing to the `HStack` and the accessory to its frame.
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(subtitle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if accessoryWidth > 0 {
                accessory
                    .frame(width: accessoryWidth, alignment: .trailing)
            }
        }
        // Pinned, not natural: the glyph tile is 28, the two text lines are 31,
        // and a segmented picker is shorter than both. Letting the tallest of the
        // three decide would make a row's height depend on whether it has a
        // control, and the section's height depend on which rows are showing.
        .frame(height: 32)
        .opacity(enabled ? 1 : 0.5)
        .help(hint)
    }
}

/// The one thing worth saying about the current state, beside the options rather
/// than under them. Only ever one at a time and ordered by how much trouble the
/// reader is in — a panel nobody is managing outranks a password prompt, which
/// outranks advice — because a column of warnings trains people to read none.
struct NotePanel<Action: View>: View {
    let symbol: String
    let title: String
    let text: String
    let tone: ModuleTone
    @ViewBuilder var action: Action

    /// Louder than `ModuleTone.fill`, which is tuned for a card sitting on the
    /// window's background. This one sits inside a card that already uses that
    /// fill, so the same value would have made it invisible.
    private var background: Color {
        tone == .idle ? .primary.opacity(0.07) : tone.accent.opacity(0.10)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // The action sits on the heading's line rather than under the text.
            // It is the same button either way, and this way the panel's worst
            // case is one line shorter — which is one line the section around it
            // does not have to reserve and then leave blank in every other state.
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(tone == .idle ? Color.secondary : tone.accent)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tone == .idle ? Color.secondary : tone.accent)
                    .lineLimit(1)
                Spacer(minLength: 8)
                action
            }
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                // Bounded so a long controller message cannot push this panel
                // past its section's fixed height. Nothing is lost: the full text
                // is the tooltip.
                .lineLimit(3)
                .help(text)
        }
        .padding(10)
        // Width fills its column, height hugs the text. Stretching it to the
        // options list's height instead drew a block of flat colour two thirds
        // empty, which reads as a rendering fault rather than a note.
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(background, in: RoundedRectangle(cornerRadius: 9))
        // The visible text is capped at three lines with the remainder in
        // `.help()`, i.e. hover-only — which is no disclosure at all for anyone
        // not using a pointer. The label carries the whole thing. Children are
        // kept so the action button inside stays reachable.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title). \(text). \(tone.spoken)")
    }
}

/// A read-only label/value line inside a module. The popover is built almost
/// entirely out of these, so its accessibility is this struct's accessibility.
struct ModuleRow: View {
    let label: String
    let value: String
    var accent: Color = .secondary

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .foregroundStyle(accent)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .font(.system(size: 12))
        // One "label: value" element rather than two adjacent strings.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

/// One reading in the sensor strip: a glyph, a label, and a value.
///
/// A separate view rather than a reuse of the two above, because neither fits:
/// `StatusTile` is a 98 pt card and `ModuleRow` is a full-width label/value
/// line, and this is a small inline pill in a row of five.
///
/// **A nil value renders nothing at all.** Not a dash, not "0 W" — the chip is
/// absent. Half of this feature's rules exist to keep an unreadable sensor from
/// turning into a confident wrong number (docs/SMC_SENSORS.md §6), and this is
/// where that ends up on screen.
///
/// It still occupies its column, though — an empty chip is invisible, not
/// missing. Each chip sits under one tile of the band above and shares that
/// tile's width, so a chip that collapsed when its sensor went quiet would slide
/// every chip after it out from under the tile it belongs to.
struct SensorChip: View {
    /// Optional, because the CPU/GPU cell has none: two glyphs there left the
    /// two numbers looking like one reading, and `cpu` next to `memorychip` is
    /// not a distinction anyone should have to make at 10 pt.
    let symbol: String?
    let label: String
    let value: String?
    /// A second reading in the same chip, with its own written label — used for
    /// CPU and GPU temperature, which are one subject in two numbers.
    var secondLabel: String?
    var secondValue: String?

    var body: some View {
        if value == nil {
            Color.clear.frame(maxWidth: .infinity)
        } else if let value: String = value {
            // The measurements behind the numbers here, taken 2026-08-05 at the
            // 820 pt window: each chip gets 121.6 pt once the note has taken
            // its ideal width, and the widest chip's contents ("Battery
            // 32 °C", a 17 pt symbol) come to about 116 at 5 pt spacing and 9
            // pt padding. That 5 pt of margin was not enough — SwiftUI wants
            // slightly more for a `Text` than the string measures, and the
            // label truncated to "Batte…". 4 and 8 buy 4 pt back, which holds.
            HStack(spacing: 4) {
                if let symbol: String = symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                if !label.isEmpty {
                    Text(label)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(value)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    // Two written labels and two numbers measure 123.3 pt in
                    // the 129.5 pt column at the temperatures this Mac reaches,
                    // but 138.8 if both ever go three-digit. Shrinking is the
                    // honest failure there: a truncated "10…" is a number that
                    // reads as a different number, which is the one thing this
                    // strip must never print.
                    .minimumScaleFactor(secondValue == nil ? 1 : 0.8)
                if let secondLabel: String = secondLabel, let secondValue: String = secondValue {
                    Text(secondLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(secondValue)
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            // Equal widths across the strip, contents pinned left so five equal
            // boxes do not put their text at five different places.
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(ModuleTone.idle.fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(ModuleTone.idle.border, lineWidth: 1)
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label.isEmpty ? "Sensor" : label)
            .accessibilityValue(value)
        }
    }
}

/// Small print inside a module: why something is unavailable, or what will happen
/// next. Carries the module's tone so an explanation never looks louder than the
/// state it explains.
struct ModuleNote: View {
    let text: String
    var tone: ModuleTone = .idle
    var symbol: String?

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(tone.accent)
                    .padding(.top, 1)
            }
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(tone == .idle ? Color.secondary : tone.accent)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The ON / OFF / PARTIAL / RESTORE / UNKNOWN verdict, in one place because the
/// window and the menu bar panel must never disagree about it.
///
/// The priority order matters: `lidPresentation == .unknown` is checked before
/// isFullyOn/isFullyOff because those two default `lidIgnored` to false when the
/// probe is unreadable, so isFullyOff can read true — a confident "OFF" — for a
/// lid state nobody actually confirmed. See docs/ARCHITECTURE.md
/// Phase 6.
struct StatusSummary {
    let pill: String
    let tone: ModuleTone
    let detail: String
    /// The glyph the window's badge draws. It lives here rather than in the view
    /// for the same reason the wording does: the badge is the first thing read at
    /// a glance, and a symbol that disagreed with the pill beside it would be
    /// worse than no symbol at all.
    let symbol: String

    /// Each `detail` is one line at the width the window's badge gives it — the
    /// badge is a status tile like the four beside it, and a sentence that wrapped
    /// there would push its text off the line every other tile's sits on. Where
    /// one of these is too short to say the whole story, the note panel beside the
    /// options list carries the rest; every state that needs one has one.
    init(state: SystemState, pendingAuxiliaryRestore: Bool, hasCompletedFirstRead: Bool = true) {
        // Before the first probe lands there is nothing to be confident about in
        // either direction. Saying so is neutral; the alternative was an amber
        // UNKNOWN on every single launch, which trains people to ignore the one
        // tile whose job is to be believed.
        if !hasCompletedFirstRead {
            pill = "READING"
            tone = .idle
            detail = "Taking the first reading…"
            symbol = "ellipsis"
        } else if state.lidPresentation == .unknown {
            pill = "UNKNOWN"
            tone = .attention
            detail = "The lid setting could not be read."
            symbol = "questionmark"
        } else if state.isFullyOn {
            pill = "ON"
            tone = .active
            detail = "Stays awake with the lid closed."
            symbol = "checkmark"
        } else if state.isFullyOff && pendingAuxiliaryRestore {
            pill = "RESTORE"
            tone = .attention
            detail = "Off, but settings are not back yet."
            symbol = "arrow.uturn.backward"
        } else if state.isFullyOff {
            pill = "OFF"
            tone = .idle
            detail = "The lid sleeps this Mac as usual."
            symbol = "power"
        } else {
            pill = "PARTIAL"
            tone = .attention
            detail = "Half applied — a closed lid can sleep."
            symbol = "exclamationmark"
        }
    }
}

/// The screen-lock delay in words, shared for the same reason as
/// `StatusSummary`: the window and the popover describe one machine, and this
/// value used to be rendered three different ways — `5 min` / `Never` /
/// `Unknown` in the window, `300 s` / `never` / `unknown` in the popover, and a
/// bare `300` from `lidless.sh status`. The one value most likely to be
/// cross-checked between a window and a terminal was the one that needed
/// arithmetic to compare, which is exactly what `README.md`'s design claim says
/// this app avoids.
///
/// Casing follows each surface's own house style — the popover speaks in
/// lowercase throughout — so the words are shared and the case is not.
enum ScreenLockFormat {
    /// The version a person acts on. The raw seconds stay on the line below it
    /// in the window, and that is what compares to `sysadminctl` and to the CLI.
    static func headline(_ raw: String) -> String {
        switch raw {
        case "unknown": return "Unknown"
        case "off": return "Never"
        default:
            guard let seconds = Int(raw) else { return "Unknown" }
            if seconds < 60 { return "\(seconds) s" }
            if seconds < 3600 { return "\(seconds / 60) min" }
            let hours: Int = seconds / 3600
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
    }

    /// Same words, the popover's voice.
    static func compact(_ raw: String) -> String {
        let text: String = headline(raw)
        return text == "Never" || text == "Unknown" ? text.lowercased() : text
    }
}

/// Session arithmetic, shared for the same reason as `StatusSummary`.
enum SessionClock {
    static func duration(_ seconds: TimeInterval) -> String {
        let total: Int = Int(seconds)
        let hours: Int = total / 3600
        let minutes: Int = (total % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    /// How long the current session has been running, or nil when there is none.
    static func elapsed(since started: Date?, active: Bool) -> String? {
        guard active, let started else { return nil }
        let seconds: TimeInterval = Date().timeIntervalSince(started)
        guard seconds >= 0 else { return nil }
        return duration(seconds)
    }

    /// How long until a time limit powers the Mac off. Nil when no limit is set,
    /// no session is running, or the limit is already due — the watchdog, not a
    /// label, decides what happens then.
    static func remaining(hours: Int, since started: Date?, active: Bool) -> String? {
        guard hours > 0, active, let started else { return nil }
        let left: TimeInterval = Double(hours) * 3600 - Date().timeIntervalSince(started)
        guard left > 0 else { return nil }
        return duration(left)
    }
}

struct ContentView: View {
    private static let panelRefreshInterval: TimeInterval = 5

    /// Fixed layout metrics. The window must not resize when a state changes, so
    /// nothing here is content-driven: every section has its own fixed height and
    /// every row inside them keeps its height whether its controls are showing or
    /// not.
    ///
    /// Every height here is measured, not guessed — with a `GeometryReader`
    /// temporarily dropped into the section's body (`.background(GeometryReader
    /// { g in Color.clear.onAppear { print(...); fflush(stdout) } })` right after
    /// `.padding(12)`, before `.frame(...)`) and every conditional note forced on
    /// in turn — one at a time for notes that are mutually exclusive in the real
    /// UI, or the sum overstates the true worst case. Then run the compiled
    /// binary directly, not via `open`, so stdout reaches the terminal. This
    /// reports the ideal height at whatever width the section actually renders
    /// at, which matters: text wraps differently at every width, so a number
    /// measured in one layout does not carry over to another. See
    /// docs/ARCHITECTURE.md
    ///
    /// Landscape as of 2026-08-02, replacing a 600 pt-wide column of cards that
    /// had grown to 728 pt tall. The width buys back the height twice over: a
    /// status band across the top holds readings that were four separate blocks
    /// of label-and-value rows before, and the options are three small sections
    /// instead of four cards each carrying their own state and explanations.
    /// 820 pt was chosen to clear the Dock at the bottom of a 13-inch screen with
    /// room to spare — the previous full-width experiment failed at 910 pt for
    /// exactly that reason (docs/ARCHITECTURE.md).
    ///
    /// Options are grouped by what they cost you to answer, not by subject: a
    /// plain yes/no goes in **Options**, and the two that also want a mode or a
    /// duration go in **Screen** with the note that explains the current state.
    /// The two sit side by side rather than stacked because a fourth stacked
    /// section costs a header, two paddings and a gap — about 55 pt — for nothing
    /// but the split, and the whole point of this layout is the height.
    ///
    /// The band's 98 is a constant rather than a worst case: every block in it is
    /// a `StatusTile` with three single-line labels, so no state can make it
    /// taller. That is the point of the shape, not a side effect of it.
    private static let windowWidth: CGFloat = 820
    private static let bandHeight: CGFloat = 98
    private static let limitsHeight: CGFloat = 106
    /// A separate, almost-square card beside the shutdown controls. Keeping it
    /// out of the shutdown card means permission never collapses into a thin
    /// footer or gets displaced by another warning.
    private static let permissionCardWidth: CGFloat = 112
    /// The sensor strip. A single row of chips and one note, so like the band
    /// above it no state can make it taller — but it is measured all the same,
    /// by the recipe in the comment above. Present at this height even with
    /// every chip empty: with `.windowResizability(.contentSize)`, a strip that
    /// appeared when the first sample landed would resize the window a second
    /// after launch, which is the exact jump this whole block exists to prevent.
    ///
    /// The sensor strip: one row of chips, one chip per tile of the band above
    /// and each the same width as its tile. 23 pt measured at 792 pt wide with
    /// every chip populated — the measurement has to be taken *after* the first
    /// sample lands, because an empty strip measures 0.
    ///
    /// A note, when there is one, replaces the row instead of adding a line to
    /// it, so this one number covers both cases and the window never resizes.
    /// It was briefly two rows; the note line measured 14 pt and was written
    /// down as 13, and one point short was enough for the note to vanish
    /// entirely rather than render clipped — which is the argument for
    /// measuring every height here rather than estimating it.
    private static let sensorStripHeight: CGFloat = 23
    private static let sectionSpacing: CGFloat = 11

    /// Both sections in the middle row draw this, so the row has one bottom edge
    /// rather than two. Set by whichever of the two is taller — Screen at 215,
    /// against Options at 198 — and shared rather than left to each: letting the
    /// shorter one end where its content does is exactly the ragged pair that
    /// read as a rendering fault the last time this layout was tried
    /// (docs/ARCHITECTURE.md). The 17 pt between them, and whatever Screen's note
    /// is short of its own worst case, is spread through each section by the
    /// `Spacer`s inside them rather than left in a band along the bottom.
    private static let sectionRowHeight: CGFloat = 215

    /// Screen is fixed and Options takes the rest. This way round because Screen
    /// is the one with a hard minimum: a row of it is a checkbox, a glyph, its
    /// text and a `rowAccessoryWidth` picker, and squeezing it would truncate the
    /// live panel state that is the whole reason that line exists.
    private static let screenSectionWidth: CGFloat = 465

    /// The verdict tile. Fixed rather than proportional so the readings beside it
    /// keep their width when the verdict changes length — "UNKNOWN" is five
    /// characters longer than "ON", and a band that reflowed on a failed probe
    /// would move every reading at the moment they matter most. 230 is what its
    /// own detail line needs to stay on one line: every string in
    /// `StatusSummary.detail` is written to fit it, as is the session line that
    /// replaces them while Lidless is on.
    private static let heroWidth: CGFloat = 230

    /// Width for a row's trailing control. One value for both rows that have one,
    /// so the two segmented pickers line up instead of ending at two different
    /// places. 188 is the wider one's own intrinsic width at `.controlSize(.small)`
    /// — "Virtual display / Keep panel on" — read off a capture rather than
    /// guessed, because a segmented picker does not compress below it: give it
    /// less and it overflows the frame and draws over the text beside it instead.
    /// Every point spent here comes straight out of that text.
    private static let rowAccessoryWidth: CGFloat = 188

    /// Both shutdown menus, so "Never" and "8 hours" sit under the same right
    /// edge whichever is selected.
    private static let limitMenuWidth: CGFloat = 130

    /// Everything the pending-shutdown card replaces, so it can be pinned to
    /// exactly the same box. Previously this arithmetic was written out at the one
    /// place that needed it, which is how a card added to the layout made the
    /// window jump at the one moment it must not.
    private static var bodyHeight: CGFloat {
        sectionRowHeight + sectionSpacing + limitsHeight
    }

    @ObservedObject var controller: Lidless

    @AppStorage(Keys.keepAwakeOnBattery) private var keepAwakeOnBattery = true
    @AppStorage(Keys.lowPowerWhileActive) private var lowPowerWhileActive = false
    @AppStorage(Keys.relaxScreenLock) private var relaxScreenLock = false
    @AppStorage(Keys.stopAllCaffeinate) private var stopAllCaffeinate = false
    @AppStorage(Keys.disableOnQuit) private var disableOnQuit = true
    @AppStorage(Keys.screenLockDelay) private var screenLockDelay = 3600
    @AppStorage(Keys.shutdownAfterHours) private var shutdownAfterHours = 0
    @AppStorage(Keys.shutdownBelowBatteryPercent) private var shutdownBelowBatteryPercent = 0
    @AppStorage(Keys.blackoutBuiltinDisplay) private var blackoutBuiltinDisplay = false
    /// Stored as its raw string, not as a `PanelMode`: a value written by hand
    /// with `defaults write` has to survive being unrecognised, and
    /// `SystemProbe.panelMode` is the single place that decides what
    /// unrecognised means. Binding the enum directly would scatter that.
    @AppStorage(Keys.panelMode) private var panelModeRaw = PanelMode.default.rawValue

    @State private var ticker: Timer?
    /// Whether the Panel blackout confirmation is on screen. `README.md:103`
    /// says "Read this before turning it on" about the one option that changes
    /// what you can see — and the in-app version of that warning
    /// (`panelBlackoutNote`) only appears *after* the option is on. This alert
    /// is the before. Only ticking the box ON asks; unticking, and a
    /// `lidless.sh set blackoutBuiltinDisplayV1 1` from a terminal, do not —
    /// the first removes the risk, the second was typed out in full.
    @State private var confirmingPanelBlackout = false

    // MARK: Derived state

    private var panelMode: PanelMode { SystemProbe.panelMode(in: panelModeRaw) }

    private var needsPrivilegeSetup: Bool {
        SystemProbe.privilegeSetupBlocksEnable(
            shutdownAfterHours: shutdownAfterHours,
            shutdownBelowBatteryPercent: shutdownBelowBatteryPercent,
            privilegedSupportInstalled: controller.state.privilegedSupportInstalled
        )
    }

    private var automaticShutdownConfigured: Bool {
        shutdownAfterHours > 0 || shutdownBelowBatteryPercent > 0
    }

    private var shutdownPending: Bool {
        controller.automaticShutdownPending || controller.externalAutomaticShutdownPending
    }

    private var summary: StatusSummary {
        StatusSummary(
            state: controller.state,
            pendingAuxiliaryRestore: controller.hasPendingAuxiliaryRestore,
            hasCompletedFirstRead: controller.hasCompletedFirstRead
        )
    }

    /// Names the power sources Low Power Mode is on for, rather than spelling out
    /// on/off for each: "AC · battery", "AC", "battery", or "off" when neither.
    /// An unreadable half is never folded into that list — it would read as a
    /// confident "not on there" — so it is named as unknown instead.
    ///
    /// "battery" is lower case and "AC" is not, which looks inconsistent and is
    /// not: AC is an initialism, battery is an ordinary noun. These are the
    /// bottom line of a status tile, alongside "not charging", "900 seconds" and
    /// "open · disablesleep 0"; a shouted BATTERY among those drew the eye to the
    /// one word in the band that least needed it.
    private var lowPowerSummary: String {
        guard controller.state.lowPowerACReadable else { return "unknown" }
        let acOn: Bool = controller.state.lowPowerAC
        guard controller.state.hasBattery else { return acOn ? "AC" : "off" }
        guard controller.state.hasBatteryReadable, controller.state.lowPowerBatteryReadable else {
            return acOn ? "AC · battery unknown" : "off · battery unknown"
        }
        let sources: [String] = [
            acOn ? "AC" : nil,
            controller.state.lowPowerBattery ? "battery" : nil,
        ].compactMap { $0 }
        return sources.isEmpty ? "off" : sources.joined(separator: " · ")
    }

    /// The battery tile's headline: the charge on its own, because the source it
    /// is running from is the line underneath it.
    private var batteryValue: String {
        guard controller.state.powerSourceReadable else { return "unknown" }
        guard let percent = controller.state.batteryPercent else { return "—" }
        return "\(percent)%"
    }

    /// Source and estimate in one line — "AC · not charging", "battery · 1:04
    /// left". Written short on purpose: the tile is a fifth of the window wide,
    /// and anything longer truncates.
    private var batteryDetail: String {
        BatteryPresentation.detail(
            sourceReadable: controller.state.powerSourceReadable,
            externalConnected: controller.state.batteryExternalConnected,
            onBattery: controller.state.onBattery,
            drainReadable: controller.state.batteryDrainReadable,
            milliamps: controller.state.batteryAmperageMilliamps,
            drainingOnAC: drainingOnAC,
            time: controller.state.batteryTime
        )
    }

    /// Only ever true from a confirmed read: a warning that might mean "nobody
    /// looked" is worse than no warning.
    private var drainingOnAC: Bool {
        controller.state.batteryDrainReadable && controller.state.batteryDrainingOnAC
    }

    private var chargingNow: Bool {
        BatteryPresentation.isCharging(
            drainReadable: controller.state.batteryDrainReadable,
            milliamps: controller.state.batteryAmperageMilliamps
        )
    }

    private var onExternalPower: Bool {
        BatteryPresentation.onExternalPower(
            externalConnected: controller.state.batteryExternalConnected,
            onBattery: controller.state.onBattery
        )
    }

    /// Green while the battery is gaining or full, amber while it is losing in a
    /// way that matters, grey otherwise.
    ///
    /// The amber cases come first and cannot collide with the green ones: sleep
    /// disabled on battery is the combination that flattens a Mac in a bag, and
    /// draining while plugged in is the same outcome by a route that looks safe.
    ///
    /// Green needs both sources because neither answers alone. `pmset` names
    /// charging and charged but prints `(no estimate)` for a while after the
    /// plug goes in — the tile read "AC · estimating…" in grey while the battery
    /// was visibly filling. The `ioreg` current knows immediately, but only says
    /// which way the charge is moving, and a full battery on AC moves none.
    private var batteryTone: ModuleTone {
        // Charge going in wins outright, and is checked first: a battery that is
        // filling is not running the Mac down, whatever `pmset` still believes
        // the power source to be. The tile went amber over a `battery ·
        // estimating…` that was 26 W of charge going the other way.
        if chargingNow { return .active }
        if (!onExternalPower && controller.state.lidIgnored) || drainingOnAC {
            return .attention
        }
        switch controller.state.batteryTime {
        case .charged, .toFull:
            return .active
        default:
            return .idle
        }
    }

    /// Every tile in the band names a subject, then answers for it, then shows the
    /// raw reading — so this one is "Lid" / "Ignored" / "open · disablesleep 1",
    /// not "Lid open" / "Ignored" / "disablesleep 1". Leading with the hinge
    /// position made this the one tile whose headline was a state rather than a
    /// subject, and reading across the band it was the one that did not fit.
    private var lidTileValue: String {
        switch controller.state.lidPresentation {
        case .ignored: return controller.state.hasLid ? "Ignored" : "Blocked"
        case .normal: return "Normal"
        case .unknown: return "Unknown"
        }
    }

    private var lidTileDetail: String {
        guard controller.state.hasLid else { return "no lid · disablesleep \(lidSettingValue)" }
        let hinge: String = controller.state.lidClosed ? "closed" : "open"
        return "\(hinge) · disablesleep \(lidSettingValue)"
    }

    private var lowPowerValue: String {
        guard controller.state.lowPowerACReadable else { return "Unknown" }
        return controller.state.lowPowerActiveAnywhere ? "On" : "Off"
    }

    /// The screen-lock tile's headline. The raw seconds stay on the line below, so
    /// this one is free to be the version a person can act on.
    /// The raw seconds under the screen-lock tile's headline — the number that
    /// appears in `sysadminctl`, so what the window says and what a terminal says
    /// can be compared without arithmetic.
    private var screenLockDetail: String {
        switch controller.state.screenLockDelay {
        case "unknown": return "not readable"
        case "off": return "no lock timeout"
        default: return "\(controller.state.screenLockDelay) seconds"
        }
    }

    private var screenLockDisplay: String {
        ScreenLockFormat.headline(controller.state.screenLockDelay)
    }

    /// The small print under the hero verdict: how long this session has been up
    /// and which process is holding it. The pid is the one diagnostic with no
    /// natural tile of its own, and it is the first thing anyone checking on
    /// Lidless from a terminal wants.
    private var heroSessionLine: String? {
        var parts: [String] = []
        if let elapsed: String = sessionElapsed { parts.append("Active \(elapsed)") }
        if let pid: Int = controller.state.caffeinatePID { parts.append("caffeinate pid \(pid)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The raw `pmset disablesleep` value, reported as three states rather than a
    /// bool so an unreadable probe is never shown as a confident "0".
    private var lidSettingValue: String {
        switch controller.state.lidPresentation {
        case .ignored: return "1"
        case .normal: return "0"
        case .unknown: return "unknown"
        }
    }

    private var screenLockValue: String {
        switch controller.state.screenLockDelay {
        case "unknown": return "unknown"
        case "off": return "never"
        default: return "\(controller.state.screenLockDelay) s"
        }
    }

    private var sessionActive: Bool {
        controller.state.keepAwakeActive || controller.state.lidIgnored
    }

    private var sessionElapsed: String? {
        SessionClock.elapsed(since: controller.sessionStartedAt, active: sessionActive)
    }

    private var shutdownCountdown: String? {
        SessionClock.remaining(
            hours: shutdownAfterHours,
            since: controller.sessionStartedAt,
            active: sessionActive
        )
    }

    // MARK: Module tones

    private var lidTone: ModuleTone {
        if controller.state.isOrphaned { return .attention }
        switch controller.state.lidPresentation {
        case .unknown: return .attention
        case .ignored: return .active
        case .normal:
            // caffeinate is holding but the one setting the whole tool exists for
            // is missing: the closed lid will still sleep this Mac. That is worth
            // going red for; a plain off state is not.
            return controller.state.keepAwakeActive ? .critical : .idle
        }
    }

    private var screenLockRestorePending: Bool {
        relaxScreenLock && controller.state.isFullyOff && controller.hasPendingAuxiliaryRestore
    }

    private var screenLockTone: ModuleTone {
        if automaticShutdownConfigured { return .idle }
        if screenLockRestorePending { return .attention }
        return relaxScreenLock && controller.state.keepAwakeActive ? .auxiliary : .idle
    }

    /// The Screen section carries two features, so its border has to pick between
    /// two answers. The panel wins whenever it has anything to say: a dark screen
    /// with nobody managing it is the only state in this window someone has to
    /// act on blind, and a purple "relaxed" border would bury it.
    private var screenTone: ModuleTone {
        let panel: ModuleTone = panelTone
        if panel == .critical || panel == .attention { return panel }
        let lock: ModuleTone = screenLockTone
        if lock == .attention { return lock }
        if panel == .active { return panel }
        return lock
    }

    private var timerTone: ModuleTone {
        if shutdownPending { return .critical }
        if needsPrivilegeSetup { return .attention }
        return automaticShutdownConfigured ? .attention : .idle
    }

    private var panelBlackoutUnavailableReason: String? {
        if case .unavailable(let reason) = controller.panelBlackoutSupport { return reason }
        return nil
    }

    private var panelTone: ModuleTone {
        switch controller.panelPresentation {
        case .stranded: return .critical
        case .dark: return .active
        case .unknown: return blackoutBuiltinDisplay ? .attention : .idle
        case .lit: return .idle
        }
    }

    /// One line under its option's title, at the width the Screen section gives
    /// it — around 33 characters. Every string here is written to that budget;
    /// the note below the two options is where a state that needs a sentence gets
    /// one, and it has the section's full width to say it in.
    private var panelStatus: String {
        if panelBlackoutUnavailableReason != nil { return "Unavailable on this Mac" }
        switch controller.panelPresentation {
        case .stranded: return "Dark, nothing managing it"
        case .dark:
            return controller.panelEffectiveMode == .dim
                ? "Dimmed to its minimum"
                : "Dark — on a virtual display"
        case .unknown: return "Unknown — cannot read the panel"
        case .lit:
            if !blackoutBuiltinDisplay { return "Lit — untouched" }
            let verb: String = controller.panelEffectiveMode == .dim ? "dims" : "darkens"
            return controller.state.isFullyOn
                ? "Lit — \(verb) when the lid shuts"
                : "Lit — arms when Lidless is on"
        }
    }

    // MARK: Module statuses

    /// Written to the same one-line budget as `panelStatus`, for the same reason.
    private var screenLockStatus: String {
        if automaticShutdownConfigured { return "Blocked by the shutdown limit" }
        if screenLockRestorePending { return "Your value is not back yet" }
        if relaxScreenLock && controller.state.keepAwakeActive { return "Relaxed to \(screenLockValue)" }
        return "Untouched — your own setting"
    }

    private var timerStatus: String {
        if shutdownPending { return "Shutting this Mac down" }
        if needsPrivilegeSetup { return "Permission not installed" }
        if let countdown: String = shutdownCountdown { return "Powers off in \(countdown)" }
        if automaticShutdownConfigured { return "Armed" }
        return "No limits set"
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: Self.sectionSpacing) {
            statusBand
                .frame(height: Self.bandHeight)

            sensorStrip
                .frame(height: Self.sensorStripHeight)

            if shutdownPending {
                shutdownCard
            } else {
                HStack(alignment: .top, spacing: Self.sectionSpacing) {
                    optionsCard
                    screenCard
                        .frame(width: Self.screenSectionWidth)
                }
                HStack(alignment: .top, spacing: Self.sectionSpacing) {
                    limitsCard
                    permissionCard
                }
            }

            actions
        }
        .padding(14)
        .frame(width: Self.windowWidth)
        // Poll quickly only while the panel is open; the controller's own
        // heartbeat keeps the watchdog alive the rest of the time.
        .onAppear {
            controller.refresh()
            ticker = Timer.scheduledTimer(
                withTimeInterval: Self.panelRefreshInterval,
                repeats: true
            ) { _ in
                Task { @MainActor in controller.refresh() }
            }
            // `.common`, like every other timer in this file. Without it this
            // one stops firing whenever a tracking loop runs — a menu open, a
            // window drag, a picker held down — while the sensor strip's timer,
            // which is in `.common`, keeps going. The strip then updates around
            // a Charge chip that does not, which is exactly how it was reported.
            if let ticker { RunLoop.main.add(ticker, forMode: .common) }
            // Separate call, not folded into the ticker above: sensors are
            // sampled on their own timer that must never share a path with
            // `refresh()`. See Lidless's Sensors section.
            controller.sensorSurfaceDidAppear()
        }
        .onDisappear {
            ticker?.invalidate()
            ticker = nil
            controller.sensorSurfaceDidDisappear()
        }
    }

    // MARK: Status band

    /// The verdict, then the four readings behind it. This band replaced a header
    /// line plus the label-and-value rows that used to sit at the bottom of each
    /// of four cards: the same numbers, but in one place and readable without
    /// first working out which card owned which.
    ///
    /// An `HStack`, not a `Grid`: a Grid row grows to whatever height its cells'
    /// `maxHeight: .infinity` will accept, and with
    /// `.windowResizability(.contentSize)` that inflated the window to 824 pt of
    /// mostly empty cards the last time it was tried.
    @ViewBuilder private var statusBand: some View {
        HStack(spacing: Self.sectionSpacing) {
            // The verdict, as the same tile as the readings beside it. Its detail
            // line prefers the live session over the explanation, the way the
            // menu bar popover already does: with "ON" right above it, "Stays
            // awake with the lid closed" says less than the elapsed time and the
            // pid holding it.
            StatusTile(
                symbol: summary.symbol,
                title: "Lidless",
                value: summary.pill,
                detail: heroSessionLine ?? summary.detail,
                tone: summary.tone,
                prominent: true
            )
            .frame(width: Self.heroWidth)

            // Desktops have no battery to report, so the tile is absent rather
            // than permanently "unknown" — the same rule the battery-time row
            // followed before it moved here.
            if controller.state.hasBattery {
                StatusTile(
                    symbol: onExternalPower ? "battery.100.bolt" : "battery.50",
                    title: "Battery",
                    value: batteryValue,
                    detail: batteryDetail,
                    tone: batteryTone
                )
            }

            StatusTile(
                symbol: controller.state.hasLid ? "laptopcomputer" : "desktopcomputer",
                title: controller.state.hasLid ? "Lid" : "Sleep block",
                value: lidTileValue,
                detail: lidTileDetail,
                tone: lidTone
            )

            StatusTile(
                symbol: "leaf.fill",
                title: "Low Power Mode",
                value: lowPowerValue,
                detail: BatteryPresentation.source(
                    sourceReadable: controller.state.powerSourceReadable,
                    externalConnected: controller.state.batteryExternalConnected,
                    onBattery: controller.state.onBattery
                ),
                tone: controller.state.lowPowerActiveAnywhere ? .active : .idle
            )

            StatusTile(
                symbol: screenLockTone == .auxiliary ? "lock.open.fill" : "lock.fill",
                title: "Screen lock",
                value: screenLockDisplay,
                detail: screenLockDetail,
                tone: screenLockTone
            )
        }
    }

    // MARK: Sensor strip

    /// What holding the Mac awake costs: system power, and how hot the parts
    /// carrying it are. Everything here comes from the SMC through
    /// `Sources/SMCSensors.swift`, on its own timer, and none of it is part of
    /// the state machine above — see that file's header.
    ///
    /// Decorative by intent: `ModuleTone.idle` throughout, so a row of live
    /// numbers never competes with the band that reports whether anything is
    /// wrong.
    @ViewBuilder private var sensorStrip: some View {
        // A note replaces the whole row rather than sitting beside it. There is
        // no spare column — every chip is under a tile and is that tile's width
        // — and both remaining notes mean the readings are not there to show:
        // one says the sampler stopped, the other that this Mac has no sensors.
        // A row of blanks with an explanation crammed into the end of it says
        // less than the explanation on its own.
        if let note: String = sensorNote {
            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // One column per tile, in the band's own order and at the band's own
            // spacing, so every chip sits under the tile it belongs to and is
            // exactly as wide. `statusBand` gives the verdict tile
            // `Self.heroWidth` and lets the rest divide what is left equally;
            // this row does the same thing with the same constants, which is
            // what keeps the two aligned when either changes.
            HStack(spacing: Self.sectionSpacing) {
                // Under the verdict tile. First because it is the only chip
                // here that can be a decision: the other four report how the
                // Mac is doing, this one reports whether it is winning or
                // losing charge. Its data comes from the `ioreg` probe rather
                // than the SMC — direction is what matters, and the SMC's
                // battery keys report a magnitude without one.
                SensorChip(symbol: "bolt.batteryblock", label: chargeChip?.label ?? "Charge",
                           value: chargeChip?.value)
                    .frame(width: Self.heroWidth)

                SensorChip(symbol: "bolt.fill", label: "Power",
                           value: SensorFormat.watts(controller.sensors.systemWatts))

                // CPU and GPU share one cell: two written labels, two numbers,
                // a degree sign on each. The glyphs that used to do the
                // labelling here did not — `cpu` and `memorychip` are two small
                // rounded squares at 10 pt. Dropping both pays for the words:
                // 117 pt against the column's 129.5 at two-digit temperatures.
                // The scale is spelled out by the Battery chip next door;
                // "CPU 54 °C GPU 45 °C" needs 141 pt and does not fit.
                SensorChip(symbol: nil, label: "CPU",
                           value: temperaturePair?.cpu,
                           secondLabel: "GPU",
                           secondValue: temperaturePair?.gpu)

                // Gated on the same condition as the Battery *tile*, which is
                // what keeps the column count equal to the tile count: a desktop
                // loses one tile from the band and one chip from here, and it
                // has no battery temperature to show anyway.
                if controller.state.hasBattery {
                    SensorChip(symbol: "battery.100", label: "Battery",
                               value: SensorFormat.celsius(controller.sensors.batteryCelsius))
                }

                // Back in the window, in the column the merged temperature cell
                // freed. It has never shown a speed and cannot on this machine:
                // 2130 SMC keys, none of them `F*` (docs/SMC_SENSORS.md §3), so
                // it reads "No Data" — the same answer the charge chip gives a
                // desktop, for the same reason.
                SensorChip(symbol: "fan", label: "Fan",
                           value: SensorFormat.fan(controller.sensors.fanRPM,
                                                   sampled: controller.sensors.sampled))
            }
        }
    }

    /// The CPU and GPU temperatures for the shared cell, or nil when neither
    /// reads. Computed once rather than at each of the two call sites, so the
    /// pair cannot end up formatted by two different passes.
    private var temperaturePair: (cpu: String, gpu: String?)? {
        SensorFormat.temperaturePair(
            cpu: controller.sensors.cpuCelsius,
            gpu: controller.sensors.gpuCelsius
        )
    }

    /// The charge chip's label and value, or nil when the probe did not read.
    ///
    /// Gated on `batteryDrainReadable`, not on the value being non-nil: 0 W is
    /// a real answer here (a full battery on AC), and only the flag separates
    /// that from a probe that never ran.
    ///
    /// A confirmed desktop skips that gate entirely and reports "No Data" — the
    /// probe never runs there because there is no battery node to read, and an
    /// empty chip would read as a broken sensor rather than as a Mac mini.
    /// `hasBatteryReadable` is required as well, so a Mac whose battery
    /// presence could not be established stays blank instead of being told it
    /// is a desktop.
    private var chargeChip: (label: String, value: String)? {
        if controller.state.hasBatteryReadable && !controller.state.hasBattery {
            return SensorFormat.charge(nil, hasBattery: false)
        }
        guard controller.state.batteryDrainReadable else { return nil }
        return SensorFormat.charge(
            controller.state.batteryPowerWatts,
            adapterWatts: controller.state.adapterWatts
        )
    }

    /// One note at most. The rule and the wording live in `SensorFormat.note`,
    /// shared with the popover so the two surfaces cannot drift.
    private var sensorNote: String? {
        SensorFormat.note(controller.sensors,
                          lowPowerActive: controller.state.lowPowerActiveAnywhere)
    }

    // MARK: Sections

    /// The options that are a plain yes or no. Four cards used to carry a few
    /// checkboxes each plus their own state rows and their own notes; moving the
    /// state into the band above left the options themselves as one short list,
    /// which is what they always were.
    ///
    /// The two that also take a mode or a duration are not here — they are in
    /// `screenCard`, with the note that explains what the answer is currently
    /// doing. Splitting on "does this need a second answer" rather than on
    /// subject keeps this list scannable: every line is a box you tick and
    /// nothing else.
    private var optionsCard: some View {
        SectionCard(
            symbol: "checklist",
            title: "Options",
            trailing: nil,
            tone: .idle,
            height: Self.sectionRowHeight
        ) {
            // Spacers between the rows, not a `spacing:` value: the row's height
            // is shared with Screen, so whatever this list is short of it gets
            // spread between the rows instead of pooling under the last one.
            VStack(alignment: .leading, spacing: 0) {
                if controller.state.hasBattery {
                    OptionRow(
                        symbol: "moon.fill",
                        tint: .indigo,
                        title: "Keep awake on battery too",
                        subtitle: "On battery too, not only on AC power.",
                        isOn: $keepAwakeOnBattery,
                        hint: "Uses caffeinate -si. Without this, macOS only honours it on AC power."
                    ) { }

                    Spacer(minLength: 6)
                }

                OptionRow(
                    symbol: "leaf.fill",
                    tint: .green,
                    title: "Low Power Mode while active",
                    subtitle: "Runs cooler and quieter while on.",
                    isOn: $lowPowerWhileActive,
                    hint: "Your previous setting is restored on Disable."
                ) { }

                Spacer(minLength: 6)

                OptionRow(
                    symbol: "terminal.fill",
                    tint: .orange,
                    title: "Stop other caffeinate on disable",
                    subtitle: "Other apps may be running it too.",
                    isOn: $stopAllCaffeinate,
                    hint: "Off by default: this stops every caffeinate process on the Mac, not only the one Lidless started."
                ) { }

                Spacer(minLength: 6)

                OptionRow(
                    symbol: "power",
                    tint: .blue,
                    title: "Disable when quitting",
                    subtitle: "Quitting does everything Disable does.",
                    isOn: $disableOnQuit,
                    hint: "Careful over remote desktop: with the lid shut, this lets the Mac sleep and you lose the connection until you open it."
                ) { }
            }
        }
    }

    /// The two options that ask a second question, and the note that answers for
    /// them. Both decide what the built-in screen does behind a shut lid, which
    /// is why they share a section — but they stay independently switchable
    /// rather than becoming two positions of one control. Relaxing the lock costs
    /// an account password twice and is a security change; darkening the panel
    /// costs no password and is undone by opening the lid. A single either/or
    /// would have removed "panel dark AND no password prompts", which is the
    /// combination this whole app exists for.
    private var screenCard: some View {
        SectionCard(
            symbol: "display",
            title: "Screen",
            trailing: nil,
            tone: screenTone,
            height: Self.sectionRowHeight
        ) {
            VStack(alignment: .leading, spacing: 6) {
                OptionRow(
                    symbol: controller.panelPresentation == .lit ? "sun.min.fill" : "macbook.slash",
                    tint: panelTone == .idle ? .purple : panelTone.accent,
                    title: "Darken the built-in screen",
                    // The panel's own state, because unlike every other option it
                    // has no tile in the band above — and it is the one thing in
                    // this window someone may have to act on without being able
                    // to see it.
                    subtitle: panelStatus,
                    // Ticking ON is intercepted for confirmation; see
                    // `confirmingPanelBlackout`. OFF passes straight through.
                    isOn: Binding(
                        get: { blackoutBuiltinDisplay },
                        set: { wantsOn in
                            if wantsOn {
                                confirmingPanelBlackout = true
                            } else {
                                blackoutBuiltinDisplay = false
                            }
                        }
                    ),
                    enabled: panelBlackoutUnavailableReason == nil,
                    hint: "Takes the built-in panel down while Lidless is on and the lid is shut, so a screen nobody can see is not left lit. How it does that is the picker beside it.",
                    accessoryWidth: Self.rowAccessoryWidth
                ) {
                    // Bound through `SystemProbe.panelMode` rather than to the raw
                    // string, so a hand-written `defaults write panelModeV1
                    // sideways` shows the default selected instead of no
                    // selection at all.
                    Picker("", selection: Binding(
                        get: { panelMode },
                        set: { panelModeRaw = $0.rawValue }
                    )) {
                        ForEach(PanelMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    // `.controlSize`, not `.font`: a segmented picker on macOS is
                    // an NSSegmentedControl and ignores the SwiftUI font entirely.
                    // Setting the font looked like it worked and did nothing, and
                    // the control kept its full-size intrinsic width — which is
                    // wider than the row reserved for it, so it drew straight over
                    // the option's own title instead of compressing.
                    .controlSize(.small)
                    // Greyed rather than hidden: the choice is part of what the
                    // option means, and a control that appears only after ticking
                    // a box is one people do not know exists until they have
                    // already committed. Leaving it in place costs nothing — the
                    // row reserves its width either way, so showing it never
                    // moves anything beside it.
                    .disabled(!blackoutBuiltinDisplay || panelBlackoutUnavailableReason != nil)
                    .help(panelMode == .dim
                        ? "Leaves the display switched on and only lowers its brightness. Nothing about the session changes, so there are no display artefacts — but the panel is very dim rather than off, and it cannot go wrong in a way that costs you the screen."
                        : "Moves the session to a virtual display and switches the panel off. Fully dark, at the cost of 1x instead of 2x density, window positions and Spaces that are not guaranteed, and a remote desktop stream that renegotiates.")
                }

                OptionRow(
                    symbol: "lock.fill",
                    tint: .purple,
                    title: "Also relax the screen lock",
                    subtitle: screenLockStatus,
                    isOn: $relaxScreenLock,
                    // Off is always reachable, even while a shutdown limit
                    // blocks turning it ON. Plain `!automaticShutdownConfigured`
                    // left a ticked box disabled — a control showing a state the
                    // user cannot leave from where they are standing. Unticking
                    // it for them would be worse: it is their setting, and it
                    // becomes live again the moment the limit is cleared.
                    enabled: !automaticShutdownConfigured || relaxScreenLock,
                    hint: automaticShutdownConfigured
                        ? "Automatic shutdown cannot restore this without your account password, so it stays off while a limit is set. You can still untick it."
                        : "macOS requires your account password when Lidless changes this setting and when it restores the original value.",
                    accessoryWidth: Self.rowAccessoryWidth
                ) {
                    Picker("", selection: $screenLockDelay) {
                        Text("5 min").tag(300)
                        Text("15 min").tag(900)
                        Text("1 h").tag(3600)
                        Text("Never").tag(0)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(!relaxScreenLock || automaticShutdownConfigured)
                }

                // The note is a footer, not a third row: whatever it is short of
                // its own worst case shows up here rather than below it.
                Spacer(minLength: 8)

                notePanel
            }
        }
        // The message covers both modes rather than reading `panelMode`,
        // because the mode picker is disabled until this box is ticked — a
        // confirmation tailored to "dim" would be describing a choice the
        // person has not been able to make yet, and switching to Virtual
        // display afterwards must not be the path that skips the risk text.
        .alert("Darken the built-in screen when the lid closes?", isPresented: $confirmingPanelBlackout) {
            Button("Turn it on") { blackoutBuiltinDisplay = true }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(
                "This is the one option here that changes what you can see."
                + " In Virtual display mode (the default) your session moves to a"
                + " virtual display and the panel switches off — window positions,"
                + " 2× density and Spaces are not guaranteed, and remote-desktop"
                + " streams renegotiate. Dim mode only lowers the brightness."
                + "\n\nIf the screen ever stays dark: open the lid. Failing that,"
                + " run ./lidless.sh rescue-display — from SSH if needed. A"
                + " watchdog also restores the panel by itself if Lidless stops"
                + " responding."
            )
        }
    }

    /// The note beside the options list. Only ever one at a time and ordered by
    /// how much trouble the reader is in: a screen nobody is managing outranks a
    /// lid setting that went missing, which outranks a password prompt, which
    /// outranks advice. A column of warnings trains people to read none of them.
    ///
    /// `controller.message` is NOT first, and that is the whole point of the order
    /// above. It used to be — it is the freshest thing in the window — but this
    /// panel replaced a separate always-visible notice slot, so first here means
    /// *instead of*, not *above*. Any passing message then hid the stranded-panel
    /// warning and took **Restore panel** off screen with it: the app's only
    /// in-window way back from a dark screen, suppressed by a line of text about
    /// something else. It sits below every state that carries a recovery action.
    @ViewBuilder private var notePanel: some View {
        if controller.panelPresentation == .stranded {
            NotePanel(
                symbol: "exclamationmark.octagon.fill",
                title: "Screen dark, nothing managing it",
                text: "Press Restore panel, or run lidless-display-rescue from a terminal.",
                tone: .critical
            ) {
                Button("Restore panel") { controller.restorePanel() }
                    .disabled(controller.busy)
                    .controlSize(.small)
            }
        } else if lidTone == .critical {
            NotePanel(
                symbol: "exclamationmark.octagon.fill",
                title: "A closed lid still sleeps",
                text: "caffeinate is holding, but pmset disablesleep is not set. Press Enable again.",
                tone: .critical
            ) { }
        } else if controller.state.isOrphaned {
            NotePanel(
                symbol: "exclamationmark.triangle.fill",
                title: "Nothing is managing this",
                text: "Lid close is ignored, and that survives reboots. Press Disable to clear it.",
                tone: .attention
            ) { }
        } else if controller.hasPanelToRestore {
            NotePanel(
                symbol: controller.panelRecoveryIsAutomatic
                    ? "moon.fill"
                    : "exclamationmark.triangle.fill",
                title: controller.panelRecoveryIsAutomatic
                    ? "Holding the panel down"
                    : "Nothing will put this back on its own",
                text: controller.panelRecoveryIsAutomatic
                    ? "It comes back on its own when the lid opens. Restore panel brings it back now."
                    : "Automatic recovery has stopped. Press Restore panel, or run lidless-display-rescue.",
                tone: controller.panelRecoveryIsAutomatic ? panelTone : .attention
            ) {
                Button("Restore panel") { controller.restorePanel() }
                    .disabled(controller.busy)
                    .controlSize(.small)
            }
        } else if let message: String = controller.message {
            // Below the four states above, which each carry a recovery action, and
            // above everything below, which is advice. Most of what lands here is
            // a failure, a refusal or a cancellation, so it outranks an unreadable
            // probe and a password warning — but not all of it is: three sites
            // report work in flight, and drawing those in amber made the app
            // shout at its own happy path. Hence the tone, and hence the dismiss:
            // this is the only slot of its kind, and a stale line can otherwise
            // occupy it for the rest of the session.
            NotePanel(
                symbol: controller.messageIsProgress
                    ? "clock.badge.checkmark"
                    : "exclamationmark.bubble.fill",
                title: controller.messageIsProgress ? "In progress" : "Last action",
                text: message,
                tone: controller.messageIsProgress ? .idle : .attention
            ) {
                Button("Dismiss") { controller.dismissMessage() }
                    .controlSize(.small)
            }
        } else if controller.state.lidPresentation == .unknown {
            NotePanel(
                symbol: "questionmark.circle.fill",
                title: "Lid setting unreadable",
                text: "Neither state is being claimed until the probe reads. Disable stays available.",
                tone: .attention
            ) { }
        } else if let reason: String = panelBlackoutUnavailableReason {
            // Not gated on the option being ticked any more. It used to be, so a
            // greyed-out row said only "Unavailable on this Mac" unless you had
            // already turned the thing on — while README.md promises "Lidless
            // names the missing piece".
            // Named, never folded into a bare "unsupported": which symbol went is
            // the difference between a one-line fix and a rewrite when a macOS
            // update moves something.
            NotePanel(
                symbol: "exclamationmark.circle",
                title: "Darkening unavailable",
                text: "This macOS does not provide \(reason).",
                tone: .idle
            ) { }
        } else if automaticShutdownConfigured {
            NotePanel(
                symbol: "exclamationmark.triangle.fill",
                title: "The screen lock stays yours",
                text: "Relaxing it is unavailable with a shutdown limit set: macOS cannot restore it unattended.",
                tone: .attention
            ) { }
        } else if controller.state.onBattery && controller.state.lidIgnored {
            NotePanel(
                symbol: "battery.25",
                title: "This drains the battery",
                text: "On battery with sleep disabled. Plug in, or turn Lidless off when you are done.",
                tone: .attention
            ) { }
        } else if relaxScreenLock {
            NotePanel(
                symbol: "key.fill",
                title: "Requires password",
                text: "macOS asks for your account password when Lidless relaxes the screen lock, and again when it puts your own value back.",
                tone: .auxiliary
            ) { }
        } else if blackoutBuiltinDisplay {
            NotePanel(
                symbol: controller.panelEffectiveMode == .dim ? "sun.min" : "rectangle.on.rectangle",
                title: controller.panelEffectiveMode == .dim ? "Dim, not off" : "If it comes back wrong",
                text: controller.panelEffectiveMode == .dim
                    ? "The panel stays switched on at its lowest brightness — very dim, but not dark."
                    : "If windows, Spaces or colours come back wrong after the lid opens, switch to Keep panel on.",
                tone: .auxiliary
            ) { }
        } else {
            // Never nothing. The section reserves this panel's height whether or
            // not one applies, so an empty slot is not a smaller card — it is the
            // same card with a hole in it. Saying "nothing is happening" out loud
            // is also the honest answer for the state it appears in: both options
            // above are off.
            NotePanel(
                symbol: "checkmark.shield",
                title: "Your screen is untouched",
                text: "Neither option is on: the panel stays lit behind a shut lid, and the lock keeps the delay you set yourself.",
                tone: .idle
            ) { }
        }
    }

    /// The shutdown limits, in a section of their own rather than a row in the
    /// list above: this is the only setting in the window that ends with the Mac
    /// powered off, and it takes two values rather than a checkbox.
    ///
    /// Pop-up menus, not the segmented controls this used to use. Segments cost
    /// width in proportion to how many there are, and width here is now spent on
    /// the options list beside them; a menu costs the same whether it offers four
    /// choices or forty.
    private var limitsCard: some View {
        SectionCard(
            symbol: shutdownPending ? "power" : "timer",
            title: "Turn off automatically",
            trailing: timerStatus,
            tone: timerTone,
            height: Self.limitsHeight
        ) {
            HStack(spacing: 10) {
                Text("After")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Picker("After", selection: $shutdownAfterHours) {
                    Text("Never").tag(0)
                    Text("1 hour").tag(1)
                    Text("2 hours").tag(2)
                    Text("4 hours").tag(4)
                    Text("8 hours").tag(8)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: Self.limitMenuWidth)

                // Desktops have no battery to fall below, so the control is absent
                // rather than permanently disabled.
                if controller.state.hasBattery {
                    Divider().frame(height: 18)

                    Text("Below battery")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Picker("Below battery", selection: $shutdownBelowBatteryPercent) {
                        Text("Never").tag(0)
                        Text("10%").tag(10)
                        Text("20%").tag(20)
                        Text("30%").tag(30)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: Self.limitMenuWidth)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 10))
                    Text("Real power off — unsaved work can be lost")
                        .font(.system(size: 10))
                        .lineLimit(1)
                }
                .foregroundStyle(automaticShutdownConfigured ? Color.orange : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .fixedSize(horizontal: true, vertical: false)
                .background(
                    (automaticShutdownConfigured ? ModuleTone.attention : ModuleTone.idle).fill,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(
                            (automaticShutdownConfigured ? ModuleTone.attention : ModuleTone.idle).border,
                            lineWidth: 1
                        )
                )

                Spacer(minLength: 0)
            }
        }
    }

    /// The one-time privileged setup is its own card, not a note inside another
    /// module. It stays visible at every warning priority and keeps the same
    /// footprint before and after installation.
    private var permissionCard: some View {
        let installed: Bool = controller.state.privilegedSupportInstalled
        // Neutral until the first probe lands — "Not installed" is a claim, and
        // on launch it is one the app has not checked yet.
        let checking: Bool = !controller.hasCompletedFirstRead
        let tone: ModuleTone = installed ? .active : (checking ? .idle : .attention)

        return VStack(alignment: .center, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: installed ? "lock.shield.fill" : "lock.shield")
                    .font(.system(size: 13, weight: .medium))
                Text("Permission")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }

            Text(checking ? "Checking…" : (installed ? "Installed" : "Not installed"))
                .font(.system(size: 12))
                .foregroundStyle(
                    checking ? Color.secondary : (installed ? Color.green : Color.orange)
                )
                .lineLimit(1)

            Spacer(minLength: 0)

            if installed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.green)
            } else {
                Button("Install…") { controller.openPrivilegeInstaller() }
                    .disabled(controller.busy)
                    .controlSize(.small)
                    // What it buys, not a repeat of the button's own label —
                    // which is what this tooltip used to be.
                    .help("One admin password, once. After it, Enable, Disable, Low Power Mode and automatic shutdown stop asking — and unattended shutdown starts working at all, which it cannot without this.")
            }
        }
        .foregroundStyle(tone.accent)
        .padding(10)
        .frame(
            width: Self.permissionCardWidth,
            height: Self.limitsHeight,
            alignment: .center
        )
        .background(tone.fill, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(tone.border, lineWidth: 1)
        )
    }

    /// Replaces the options and limits sections for the 60 seconds before a
    /// shutdown fires: at that point the only two useful things on screen are how
    /// long is left and how to stop it. The status band above stays put — the
    /// readings it carries are exactly what someone deciding whether to cancel
    /// wants to see.
    private var shutdownCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().strokeBorder(.red, lineWidth: 2)
                    Image(systemName: "power")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.red)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 3) {
                    countdownLabel
                    Text("A real shutdown, not sleep: running apps are terminated and unsaved work can be lost.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider().opacity(0.5)

            ModuleRow(
                label: "Keep awake",
                value: controller.state.keepAwakeActive ? "released on shutdown" : "not held",
                accent: .secondary
            )
            ModuleRow(
                label: "Low Power Mode",
                value: lowPowerSummary,
                accent: controller.state.lowPowerActiveAnywhere ? .orange : .secondary
            )
            ModuleRow(label: "Screen lock delay", value: screenLockValue)
            ModuleRow(
                label: "Built-in panel",
                value: controller.panelPresentation.summary,
                accent: controller.panelPresentation == .stranded ? .red : .secondary
            )

            // The worst compound state this app has: the screen is dark AND the
            // Mac is about to power off. This card replaces the whole middle of
            // the window, and `notePanel` — the only host of Restore panel — is
            // inside what it replaced, so that state used to have no in-app
            // recovery affordance anywhere.
            if controller.panelPresentation == .stranded || controller.hasPanelToRestore {
                HStack(spacing: 8) {
                    Button("Restore panel") { controller.restorePanel() }
                        .disabled(controller.busy)
                        .controlSize(.small)
                    Text("Bring the built-in screen back before the Mac powers off.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(
            maxWidth: .infinity,
            minHeight: Self.bodyHeight,
            maxHeight: Self.bodyHeight,
            alignment: .topLeading
        )
        .background(ModuleTone.critical.fill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.red.opacity(0.45), lineWidth: 1)
        )
    }

    /// Ticks once a second on its own, because the panel itself refreshes every
    /// five — which would show a 60-second countdown in five-second jumps.
    @ViewBuilder private var countdownLabel: some View {
        if let deadline: Date = controller.automaticShutdownDeadline {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("This Mac shuts down in \(max(0, Int(deadline.timeIntervalSince(context.date).rounded())))s")
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
            }
        } else {
            // The LaunchAgent's own pending shutdown: Lidless can cancel it, but
            // it never published a deadline to count down to.
            Text("A watchdog shutdown is pending")
                .font(.system(size: 15, weight: .semibold))
        }
    }

    /// Three buttons sharing the width, rather than two at the left and a quiet
    /// one at the right. The window is wide now, and a huddle of small controls in
    /// one corner of it reads as an afterthought. Quit keeps a border for the same
    /// reason it keeps its conditional name: it is the button most likely to be
    /// pressed by someone who has not read anything else on screen.
    private var actions: some View {
        HStack(spacing: 10) {
            if shutdownPending {
                Button {
                    controller.cancelAutomaticShutdown()
                } label: {
                    Label("Cancel shutdown", systemImage: "xmark.octagon.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.red)
            }

            Button {
                controller.enable()
            } label: {
                Group {
                    if controller.busy {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("Working…")
                        }
                    } else if controller.state.isFullyOn {
                        Label("Enabled", systemImage: "checkmark.circle.fill")
                    } else {
                        Label("Enable", systemImage: "play.circle.fill")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(controller.busy || controller.state.isFullyOn || needsPrivilegeSetup)
            // The one thing README.md insists you know before pressing this, said
            // where it is pressed. "That survives reboots" appeared exactly once
            // in the whole UI, inside the note that only shows up once the bad
            // state already exists.
            .help(needsPrivilegeSetup
                ? Lidless.privilegeSetupRequiredMessage
                : "Sets pmset disablesleep, which survives reboots and outlives this app. Disable — or Quit & disable — is what clears it.")

            Button {
                controller.disable(stopAllCaffeinate: stopAllCaffeinate)
            } label: {
                Label("Disable", systemImage: "stop.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(controller.busy || !controller.hasSomethingToRestore)

            // Named for what it will actually do, so the setting is not a
            // surprise at the moment it fires.
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label(
                    disableOnQuit && controller.hasSomethingToRestore ? "Quit & disable" : "Quit",
                    systemImage: "xmark.circle.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }
}

/// The menu bar popover. Deliberately *not* a narrow copy of the window: the
/// window's sections are built for 820 pt of width, and stacking them into a
/// popover column made it a thousand points tall. Putting that whole tree in the
/// `MenuBarExtra` scene also crashed SwiftUI's main-menu preference walk at launch
/// roughly one time in four on macOS 26.6
/// (`KEY_TYPE_OF_DICTIONARY_VIOLATES_HASHABLE_REQUIREMENTS` inside
/// `ForEachState.item(at:offset:)`, reached from
/// `AppDelegate.applicationWillFinishLaunching`). The shipped single-column UI
/// crashed the same way, so this is a pre-existing macOS 26.6 problem rather than
/// one any window layout introduced. Measurements and the rule that follows
/// from them: docs/ARCHITECTURE.md Keep this panel small.
///
/// So this is a glance-and-act panel: what is true right now, and the two buttons
/// worth having without opening the window. Every option lives in the window.
struct MenuBarPanel: View {
    private static let refreshInterval: TimeInterval = 5

    @ObservedObject var controller: Lidless

    @AppStorage(Keys.stopAllCaffeinate) private var stopAllCaffeinate = false
    @AppStorage(Keys.disableOnQuit) private var disableOnQuit = true
    @AppStorage(Keys.shutdownAfterHours) private var shutdownAfterHours = 0
    @AppStorage(Keys.shutdownBelowBatteryPercent) private var shutdownBelowBatteryPercent = 0
    @AppStorage(Keys.blackoutBuiltinDisplay) private var blackoutBuiltinDisplay = false

    @State private var ticker: Timer?
    /// The route back to the window. Without it this panel could name actions
    /// that live in the window and offer no way to get there.
    @Environment(\.openWindow) private var openWindow

    /// Shown only when the option is armed or the panel has something to report.
    /// Same rule as the battery row: a permanent line about a feature nobody
    /// turned on is one more thing to read past in a panel that must stay small.
    private var showsPanelRow: Bool {
        // Named states, not `!= .lit`. `.unknown` now also means "the display list
        // read but the brightness did not", which is the permanent condition on
        // any Mac whose private brightness getter does not work for the built-in —
        // and `!= .lit` turned that into a row that never goes away, explaining a
        // feature its owner may never have switched on.
        blackoutBuiltinDisplay
            || controller.panelPresentation == .dark
            || controller.panelPresentation == .stranded
    }

    private var summary: StatusSummary {
        StatusSummary(
            state: controller.state,
            pendingAuxiliaryRestore: controller.hasPendingAuxiliaryRestore,
            hasCompletedFirstRead: controller.hasCompletedFirstRead
        )
    }

    private var sessionActive: Bool {
        controller.state.keepAwakeActive || controller.state.lidIgnored
    }

    private var shutdownPending: Bool {
        controller.automaticShutdownPending || controller.externalAutomaticShutdownPending
    }

    private var lidValue: String {
        switch controller.state.lidPresentation {
        case .ignored: return controller.state.hasLid ? "ignored" : "sleep blocked"
        case .normal: return "normal"
        case .unknown: return "unknown"
        }
    }

    /// The same rule the window's Enable already applied, computed from the same
    /// function. `Lidless.enable()` now enforces it too, but a controller guard
    /// on its own would leave this button clickable and silently inert — worse
    /// than being visibly disabled. Belt and suspenders, matching how `busy` is
    /// already handled on both sides.
    private var needsPrivilegeSetup: Bool {
        SystemProbe.privilegeSetupBlocksEnable(
            shutdownAfterHours: shutdownAfterHours,
            shutdownBelowBatteryPercent: shutdownBelowBatteryPercent,
            privilegedSupportInstalled: controller.state.privilegedSupportInstalled
        )
    }

    private var timerValue: String {
        if shutdownPending { return "shutting down" }
        if let left = SessionClock.remaining(
            hours: shutdownAfterHours,
            since: controller.sessionStartedAt,
            active: sessionActive
        ) { return "in \(left)" }
        if shutdownAfterHours > 0 || shutdownBelowBatteryPercent > 0 { return "armed" }
        return "no limits"
    }

    /// Cased the same way as the window's `lowPowerSummary` and battery tile —
    /// "AC" is an initialism, "battery" is not. The two panels describe the same
    /// machine and must not shout in one and not the other.
    private var powerValue: String {
        guard controller.state.powerSourceReadable else { return "unknown" }
        guard controller.state.hasBattery else { return "AC" }
        let source: String = controller.state.onBattery ? "battery" : "AC"
        guard let percent = controller.state.batteryPercent else { return source }
        // Same reading as the window's Battery tile, and it belongs here for
        // the same reason: on AC this row otherwise says "AC · 85%" while the
        // percentage is going down.
        if controller.state.batteryDrainReadable && controller.state.batteryDrainingOnAC {
            return "\(source) · \(percent)% · draining"
        }
        return "\(source) · \(percent)%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text("Lidless")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 6)
                HStack(spacing: 5) {
                    Circle()
                        .fill(summary.tone.accent)
                        .frame(width: 7, height: 7)
                    Text(summary.pill)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(
                            summary.tone == .idle ? Color.secondary : summary.tone.accent
                        )
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(summary.tone.accent.opacity(0.15), in: Capsule())
            }

            if let elapsed = SessionClock.elapsed(
                since: controller.sessionStartedAt,
                active: sessionActive
            ) {
                Text("Awake for \(elapsed)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text(summary.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(spacing: 5) {
                ModuleRow(
                    label: "Keep awake",
                    value: controller.state.caffeinatePID.map { "pid \($0)" } ?? "off",
                    accent: controller.state.keepAwakeActive ? .green : .secondary
                )
                ModuleRow(
                    // "Lid", matching the window's tile title. The two surfaces
                    // called the same row different things.
                    label: controller.state.hasLid ? "Lid" : "Sleep block",
                    value: lidValue,
                    accent: controller.state.lidPresentation == .ignored ? .green : .secondary
                )
                if showsPanelRow {
                    ModuleRow(
                        label: "Built-in panel",
                        value: controller.panelPresentation.summary,
                        accent: {
                            switch controller.panelPresentation {
                            case .stranded: return .red
                            case .dark: return .green
                            default: return .secondary
                            }
                        }()
                    )
                }
                ModuleRow(
                    label: "Screen lock",
                    value: ScreenLockFormat.compact(controller.state.screenLockDelay)
                )
                ModuleRow(
                    label: "Shutdown timer",
                    value: timerValue,
                    accent: shutdownPending
                        ? .red
                        : (shutdownAfterHours > 0 || shutdownBelowBatteryPercent > 0
                           ? .orange
                           : .secondary)
                )
                ModuleRow(label: "Power", value: powerValue)
                if controller.state.hasBattery {
                    ModuleRow(label: "Battery time", value: controller.state.batteryTime.summary)
                }
                // Sensors, as rows rather than as the window's chips: this panel
                // is a single narrow column and every other value in it is a
                // `ModuleRow`. Each row appears only when its reading does —
                // the popover has to stay small (docs/ARCHITECTURE.md), and a
                // permanent row saying nothing is exactly what that rule is
                // about.
                if controller.state.batteryDrainReadable,
                   let charge = SensorFormat.charge(
                       controller.state.batteryPowerWatts,
                       adapterWatts: controller.state.adapterWatts
                   ) {
                    ModuleRow(
                        label: charge.label == "Drain" ? "Battery drain" : "Battery charge",
                        value: charge.value,
                        // The only sensor row that earns a colour: on AC this is
                        // the one that says the adapter is losing.
                        accent: controller.state.batteryDrainingOnAC ? .orange : .secondary
                    )
                }
                if let watts: String = SensorFormat.watts(controller.sensors.systemWatts) {
                    ModuleRow(label: "System power", value: watts)
                }
                if let cpu: String = SensorFormat.celsius(controller.sensors.cpuCelsius) {
                    ModuleRow(label: "CPU temp", value: cpu)
                }
                if let gpu: String = SensorFormat.celsius(controller.sensors.gpuCelsius) {
                    ModuleRow(label: "GPU temp", value: gpu)
                }
                if let battery: String = SensorFormat.celsius(controller.sensors.batteryCelsius) {
                    ModuleRow(label: "Battery temp", value: battery)
                }
                if let fan: String = SensorFormat.fan(controller.sensors.fanRPM,
                                                      sampled: controller.sensors.sampled) {
                    ModuleRow(label: "Fan", value: fan)
                }
            }

            // The same note as the window's strip, from the same function, so
            // the two surfaces cannot say different things about one reading.
            if let note: String = SensorFormat.note(
                controller.sensors,
                lowPowerActive: controller.state.lowPowerActiveAnywhere
            ) {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            // Ahead of the orphaned-lid note: a dark panel with nobody managing it
            // is the one state where this popover may be the only thing the person
            // can see — and on a notched Mac with a full menu bar it may itself be
            // unreachable (docs/ARCHITECTURE.md), which is why the window carries the
            // Restore panel button rather than this panel.
            if controller.panelPresentation == .stranded {
                ModuleNote(
                    text: "The built-in screen is dark with nothing managing it.",
                    tone: .critical,
                    symbol: "exclamationmark.octagon.fill"
                )
                // The button, not a sentence about where the button lives. This
                // is the one state where this popover may be the only thing the
                // person can see.
                Button("Restore panel") { controller.restorePanel() }
                    .disabled(controller.busy)
                    .controlSize(.small)
            } else if controller.state.isOrphaned {
                ModuleNote(
                    text: "Lid close is ignored but nothing is managing it. Press Disable.",
                    tone: .attention,
                    symbol: "exclamationmark.triangle.fill"
                )
            } else if controller.state.onBattery && controller.state.lidIgnored {
                ModuleNote(
                    text: "On battery with sleep disabled — this drains.",
                    tone: .attention,
                    symbol: "exclamationmark.triangle.fill"
                )
            }

            Divider()

            HStack(spacing: 8) {
                if shutdownPending {
                    Button("Cancel shutdown") { controller.cancelAutomaticShutdown() }
                        .tint(.red)
                        .controlSize(.small)
                }

                // Busy shows as work in progress, not only as a greyed button.
                // The window's Enable has said "Working…" with a spinner for a
                // while; here both buttons just went dim, so a privileged action
                // that takes twenty seconds made the popover look frozen.
                if controller.busy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Working…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button("Enable") { controller.enable() }
                        .controlSize(.small)
                        .disabled(controller.state.isFullyOn || needsPrivilegeSetup)
                        .help(needsPrivilegeSetup ? Lidless.privilegeSetupRequiredMessage : "")

                    Button("Disable") { controller.disable(stopAllCaffeinate: stopAllCaffeinate) }
                        .controlSize(.small)
                        .disabled(!controller.hasSomethingToRestore)
                }

                Spacer(minLength: 4)

                Button(disableOnQuit && controller.hasSomethingToRestore ? "Quit & disable" : "Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Button("Open Lidless window") {
                    openWindow(id: LidlessApp.mainWindowID)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                Text("— the options live there.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(width: 268)
        .onAppear {
            controller.refresh()
            ticker = Timer.scheduledTimer(
                withTimeInterval: Self.refreshInterval,
                repeats: true
            ) { _ in
                Task { @MainActor in controller.refresh() }
            }
            // `.common` — and this surface needs it most: the popover is opened
            // from a menu bar item, so it is shown *by* a tracking loop.
            if let ticker { RunLoop.main.add(ticker, forMode: .common) }
            controller.sensorSurfaceDidAppear()
        }
        .onDisappear {
            ticker?.invalidate()
            ticker = nil
            controller.sensorSurfaceDidDisappear()
        }
    }
}

// MARK: - App

/// SwiftUI has no scene-level hook for "the app is about to quit" that can defer
/// termination, so this goes through the old delegate.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Window restoration is switched off in Info.plist and refused again at
    /// termination below — but a saved-state bundle written by an *earlier* build
    /// can still be sitting on disk, and macOS 26.6 crashes inside
    /// `AppWindowsController.restoreWindow(withIdentifier:state:completionHandler:)`
    /// when it reads one whose window identifiers the current scene layout no
    /// longer knows. Nothing in a single-window utility wants that state, so it is
    /// discarded before AppKit can act on it: the Apple Event that drives
    /// restoration arrives after this callback. See docs/ARCHITECTURE.md
    func applicationWillFinishLaunching(_ notification: Notification) {
        discardSavedWindowState()
        // One line per launch, and it earns its place twice over: it creates the
        // text log so its location can be found before anything has gone wrong,
        // and it is the only record that says the app was running at all. "Was
        // Lidless even up when this happened?" took process archaeology to answer
        // on 2026-08-03 and is now one grep.
        PanelLog.event("launched — panel log file: \(PanelLog.filePath ?? "none")")
    }

    /// Best effort on purpose. A failure here means the state stays and the launch
    /// carries the same small risk it always did; it is not worth refusing to
    /// start over.
    private func discardSavedWindowState() {
        guard let bundleIdentifier: String = Bundle.main.bundleIdentifier else { return }
        let path: String = NSHomeDirectory()
            + "/Library/Saved Application State/\(bundleIdentifier).savedState"
        try? FileManager.default.removeItem(atPath: path)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // AppKit writes the saved-state bundle while terminating. `restorationBehavior`
        // on the scene would say this declaratively, but it needs macOS 15 and
        // SceneBuilder cannot branch on availability, so it is said here instead —
        // this runs on every supported version.
        for window: NSWindow in NSApplication.shared.windows {
            window.isRestorable = false
        }
        return MainActor.assumeIsolated { Lidless.shared.terminationReply() }
    }

    /// Closing the window leaves the app running in the menu bar, so it is not
    /// a quit and does not disable anything.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct LidlessApp: App {
    /// Identifies the one real window so `openWindow(id:)` can bring it back.
    /// The popover used to tell people to "open the Lidless window" with no way
    /// to do it: a grep of Sources/ for `openWindow`, `NSApp.activate` and
    /// `applicationShouldHandleReopen` returned nothing, so the only routes were
    /// the Dock icon and Cmd-N — neither mentioned, and the advice is given
    /// precisely when the screen may be dark.
    static let mainWindowID: String = "lidless-main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = Lidless.shared

    private var menuBarIcon: String {
        if controller.state.isOrphaned { return "exclamationmark.triangle.fill" }
        // Checked before isFullyOn/isFullyOff for the same reason as
        // ContentView.headline: those default to a confident-looking false
        // when the lid probe is unreadable.
        if controller.state.lidPresentation == .unknown { return "questionmark.circle.fill" }
        if controller.state.isFullyOn { return "bolt.fill" }
        if controller.state.isFullyOff { return "moon.zzz.fill" }
        return "bolt.badge.clock"
    }

    var body: some Scene {
        // A real window is the guaranteed way in. The menu bar item is not: macOS
        // gives each new status item the leftmost free slot, and on a notched Mac
        // whose menu bar is already full that slot is *behind* the notch, where
        // nothing is drawn and no click lands. Measured here — the item existed at
        // its normal size with its label image, and its popover opened correctly
        // when pressed through the accessibility API; it was simply never visible.
        // Nothing in this code can move it. See docs/ARCHITECTURE.md
        // WindowGroup, not Window: macOS restores saved window state by scene
        // identifier, and switching scene types makes the restore path trip an
        // assertion at launch — the app dies before showing anything. Restoration
        // is refused in Info.plist and twice more in AppDelegate; see
        // docs/ARCHITECTURE.md
        WindowGroup(id: Self.mainWindowID) {
            ContentView(controller: controller)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            // Its own compact panel, not the window's grid — see MenuBarPanel.
            MenuBarPanel(controller: controller)
        } label: {
            Image(systemName: menuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }
}
