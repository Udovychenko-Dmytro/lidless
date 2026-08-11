// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Dmytro Udovychenko

import Foundation
import CoreGraphics
import ObjectiveC

// Panel blackout's contact with the window server.
//
// Every symbol here is PRIVATE. None of it is in a header, none of it is
// guaranteed to survive a macOS point release, and none of it can be exercised by
// tests/run.sh — the fake binaries in tests/bin/ can stand in for `pmset` and
// `ioreg` because those are subprocesses on PATH, but these are in-process C and
// Objective-C calls with no seam. That is why every decision worth testing lives
// in SystemProbe.swift as a pure function and this file only carries them out.
//
// This file is deliberately NOT referenced from SystemProbe.swift. Both test
// binaries (tests/run.sh:1655 and :1691) compile SystemProbe.swift without it, and
// a single reference from there would stop the whole suite compiling.
//
// Everything below was verified by runtime probe on macOS 26.6 (25G72), M4
// MacBook Air. See docs/ARCHITECTURE.md for what was measured and what it cost.

/// Whether the private display API is usable on this Mac, and if not, exactly why.
/// The reason is carried verbatim to the UI: "not supported" tells a person
/// nothing, and the whole point of resolving symbols one at a time is to be able
/// to say which one is missing.
enum VirtualDisplaySupport: Equatable, Sendable {
    case available
    case unavailable(reason: String)
}

/// Private CoreGraphics/SkyLight entry points, resolved once and cached.
///
/// Resolution happens through `dlsym(RTLD_DEFAULT)` and `NSClassFromString` rather
/// than a link-time dependency, because build.sh compiles plain .swift files with
/// no bridging header and no `-F` search path — a link-time binding would not
/// build, and `@_silgen_name` would produce a binary that fails to launch on a
/// system where the symbol has gone rather than one that reports it.
enum DisplayAPI {
    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)

    private typealias FnConfigureDisplayEnabled =
        @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    private typealias FnGetDisplayList =
        @convention(c) (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?,
                        UnsafeMutablePointer<UInt32>?) -> CGError
    private typealias FnSetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias FnGetBrightness =
        @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias FnCanChangeBrightness = @convention(c) (CGDirectDisplayID) -> Bool

    // Each objc_msgSend cast quotes the type encoding dumped from the ObjC runtime
    // on the target machine. Getting one of these wrong is a corrupted stack, not
    // a compile error, so they are written out rather than shared.
    /// `@32@0:8I16I20d24` — `-initWithWidth:height:refreshRate:`
    fileprivate typealias MsgSendInitMode =
        @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> Unmanaged<AnyObject>?
    /// `@24@0:8@16` — `-initWithDescriptor:`
    fileprivate typealias MsgSendInitObj =
        @convention(c) (AnyObject, Selector, AnyObject?) -> Unmanaged<AnyObject>?
    /// `B24@0:8@16` — `-applySettings:`
    fileprivate typealias MsgSendApply = @convention(c) (AnyObject, Selector, AnyObject?) -> ObjCBool
    /// `I16@0:8` — `-displayID`
    fileprivate typealias MsgSendUInt32 = @convention(c) (AnyObject, Selector) -> UInt32
    fileprivate typealias MsgSendAlloc = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
    /// `v24@0:8@?16` — `-setTerminationHandler:`
    fileprivate typealias MsgSendVoidObj = @convention(c) (AnyObject, Selector, AnyObject?) -> Void

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        dlsym(rtldDefault, name)
    }

    /// DisplayServices is not linked by anything in the app, so it has to be
    /// pulled in before its symbols resolve. Loading it is harmless when the
    /// feature is off — nothing is called until the user turns blackout on.
    private static let displayServicesLoaded: Bool = {
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
               RTLD_LAZY) != nil
    }()

    private static let configureDisplayEnabled: FnConfigureDisplayEnabled? =
        symbol("CGSConfigureDisplayEnabled").map { unsafeBitCast($0, to: FnConfigureDisplayEnabled.self) }
    private static let cgsGetDisplayList: FnGetDisplayList? =
        symbol("CGSGetDisplayList").map { unsafeBitCast($0, to: FnGetDisplayList.self) }
    fileprivate static let msgSend: UnsafeMutableRawPointer? = symbol("objc_msgSend")

    private static let setBrightnessFn: FnSetBrightness? = {
        _ = displayServicesLoaded
        return symbol("DisplayServicesSetBrightness").map { unsafeBitCast($0, to: FnSetBrightness.self) }
    }()
    private static let getBrightnessFn: FnGetBrightness? = {
        _ = displayServicesLoaded
        return symbol("DisplayServicesGetBrightness").map { unsafeBitCast($0, to: FnGetBrightness.self) }
    }()
    private static let canChangeBrightnessFn: FnCanChangeBrightness? = {
        _ = displayServicesLoaded
        return symbol("DisplayServicesCanChangeBrightness")
            .map { unsafeBitCast($0, to: FnCanChangeBrightness.self) }
    }()

    /// Resolved once. A missing symbol is reported by name, never folded into a
    /// bare "unsupported" — knowing which one went is the difference between a
    /// one-line fix and a rewrite when a macOS update moves something.
    static let support: VirtualDisplaySupport = {
        for name in ["CGVirtualDisplay", "CGVirtualDisplayDescriptor",
                     "CGVirtualDisplaySettings", "CGVirtualDisplayMode"]
        where NSClassFromString(name) == nil {
            return .unavailable(reason: "\(name) is not present in this macOS")
        }
        guard configureDisplayEnabled != nil else {
            return .unavailable(reason: "CGSConfigureDisplayEnabled is not present in this macOS")
        }
        guard msgSend != nil else {
            return .unavailable(reason: "objc_msgSend could not be resolved")
        }
        guard setBrightnessFn != nil, getBrightnessFn != nil else {
            return .unavailable(reason: "DisplayServices brightness control is not present")
        }
        return .available
    }()

    // MARK: - Enumeration

    /// `nil` means the list could not be read, which is a different answer from an
    /// empty list and must stay different: `SystemProbe.blackoutDecision` refuses
    /// outright on `nil`, because an unreadable display list is never a licence to
    /// take the last display away.
    static func activeDisplayIDs() -> [UInt32]? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(32, &ids, &count) == .success else { return nil }
        return Array(ids.prefix(Int(count)))
    }

    static func onlineDisplayIDs() -> [UInt32]? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return nil }
        return Array(ids.prefix(Int(count)))
    }

    /// The window server's own list. Measured 2026-08-01: after the built-in is
    /// disabled it leaves both the active and the online list but stays in this
    /// one, which is the only reason a disabled panel can still be named.
    static func windowServerDisplayIDs() -> [UInt32]? {
        guard let fn = cgsGetDisplayList else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard fn(32, &ids, &count) == .success else { return nil }
        return Array(ids.prefix(Int(count)))
    }

    /// Found by ATTACHMENT, not by activity.
    ///
    /// Prevents the bug that made the first working version refuse to run: a panel
    /// that is merely asleep drops out of `CGGetActiveDisplayList` entirely —
    /// measured, `active=[]` while `online=[1]` — so searching the active list
    /// reports "no built-in display" on a Mac whose only display is right there.
    static func builtinDisplayID() -> UInt32? {
        for candidate in onlineDisplayIDs() ?? [] where CGDisplayIsBuiltin(candidate) != 0 {
            return candidate
        }
        for candidate in windowServerDisplayIDs() ?? [] where CGDisplayIsBuiltin(candidate) != 0 {
            return candidate
        }
        return nil
    }

    /// Confirms that an ID recorded by the recovery marker is still a virtual
    /// display. Intel WindowServer rewrites the custom descriptor identity to
    /// `unkn`/`virt`/0 in its public display records, while Apple Silicon may
    /// preserve the requested values, so both measured representations count.
    static func isVirtualDisplay(_ id: UInt32) -> Bool {
        guard CGDisplayIsBuiltin(id) == 0 else { return false }
        let identity = (
            CGDisplayVendorNumber(id),
            CGDisplayModelNumber(id),
            CGDisplaySerialNumber(id)
        )
        return identity == (
            LidlessVirtualDisplayIdentity.vendorID,
            LidlessVirtualDisplayIdentity.productID,
            LidlessVirtualDisplayIdentity.serialNumber
        ) || identity == (0x756e_6b6e, 0x7669_7274, 0)
    }

    // MARK: - Brightness

    static func brightness(of id: UInt32) -> Float? {
        guard let get = getBrightnessFn else { return nil }
        var value: Float = 0
        guard get(id, &value) == 0, value.isFinite, value >= 0, value <= 1 else { return nil }
        return value
    }

    @discardableResult
    static func setBrightness(_ value: Float, on id: UInt32) -> Bool {
        guard let set = setBrightnessFn else { return false }
        return set(id, value) == 0
    }

    /// Two of the three entries the window server reports on an M4 MacBook Air are
    /// 1x1 offline phantoms with no backlight; asking first keeps recovery from
    /// writing brightness into them.
    static func canChangeBrightness(_ id: UInt32) -> Bool {
        guard let can = canChangeBrightnessFn else { return true }
        return can(id)
    }

    // MARK: - Enable / disable

    /// Applies an enable/disable to one display.
    ///
    /// `option` was once believed to be the whole safety story: that
    /// `kCGConfigureForAppOnly` is reverted by the window server when the calling
    /// process dies, so a crash mid-blackout healed itself.
    ///
    /// **It does not, and that belief was a measurement error.** Isolated on
    /// 2026-08-01 by killing the recovery watchdog FIRST and only then `kill -9`ing
    /// the owner: 57 seconds later the built-in was still absent from the active,
    /// online and window-server lists. Both earlier measurements that "confirmed"
    /// the revert had the watchdog running and were watching it do the work — the
    /// spike's own log gives it away, with brightness jumping to that version's
    /// rescue floor two seconds after the panel came back.
    ///
    /// What IS true is the neighbouring claim, and the two are easy to conflate:
    /// the window server does tear down the owner's **virtual display** when it
    /// exits. The disable of the built-in is what outlives the process.
    ///
    /// So the option choice is now about damage limitation rather than recovery:
    /// `kCGConfigureForAppOnly` keeps the change scoped to this app so it cannot
    /// end up in the persistent display configuration, while
    /// `kCGConfigurePermanently` belongs only in the rescue tool — which exits
    /// immediately, so an app-scoped ENABLE there would be undone the instant it
    /// succeeded. Recovery itself rests on the watchdog and the rescue tool.
    @discardableResult
    static func setDisplayEnabled(_ id: UInt32, _ enabled: Bool,
                                  option: CGConfigureOption) -> Bool {
        setDisplayTopology(
            enabling: enabled ? [id] : [],
            disabling: enabled ? [] : [id],
            option: option
        )
    }

    /// Applies all requested changes in one WindowServer transaction. This must
    /// not be used as a way to make recovery permanent while a virtual carrier is
    /// live: measured on Intel, even a transaction that disables the carrier
    /// persists it as a separate active DisplaySet. Callers enforce that stronger
    /// precondition before choosing `.permanently`.
    @discardableResult
    static func setDisplayTopology(enabling enabledIDs: [UInt32],
                                   disabling disabledIDs: [UInt32],
                                   option: CGConfigureOption) -> Bool {
        guard let configure = configureDisplayEnabled else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        for id in Set(disabledIDs) {
            guard configure(config, id, false) == .success else {
                CGCancelDisplayConfiguration(config)
                return false
            }
        }
        for id in Set(enabledIDs) {
            guard configure(config, id, true) == .success else {
                CGCancelDisplayConfiguration(config)
                return false
            }
        }
        return CGCompleteDisplayConfiguration(config, option) == .success
    }

    /// Public CoreGraphics. Returns nothing at all, so whether it helped can only
    /// be established by re-reading the display list afterwards.
    static func restorePermanentConfiguration() {
        CGRestorePermanentDisplayConfiguration()
    }

    /// Polls until `id` is (or is not) in the active list. Success is decided by
    /// re-reading, never by the return code of the call that asked for it — the
    /// same rule the rest of this project applies to `pmset`.
    ///
    /// `async`, and deliberately not a `usleep` loop. Every display mutation in
    /// this project runs on the main actor because CoreGraphics display
    /// configuration is main-thread sensitive, and a blocking wait there stops
    /// the UI and every `Timer` for up to the whole timeout — including the
    /// blackout heartbeat that `lidless-display-rescue --watch` reads as proof
    /// the owner is still making progress. Blocking here would have the recovery
    /// watchdog fire on a healthy app.
    static func waitForActive(_ id: UInt32, active: Bool, timeout: TimeInterval) async -> Bool {
        // `ContinuousClock`, not `Date`. This runs between switching the built-in
        // off and confirming it went — the one stretch where the controller is
        // `busy`, the lid watcher does nothing and the heartbeat still tells the
        // recovery watchdog everything is fine. A clock pushed backwards turned a
        // five-second wait there into an open-ended one.
        let started = ContinuousClock.now
        let limit = Duration.seconds(timeout)
        while started.duration(to: .now) < limit {
            if let list = activeDisplayIDs(), list.contains(id) == active { return true }
            try? await Task<Never, Never>.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
}

/// One virtual display, alive for exactly as long as this object.
///
/// The window server tears it down when the owning process exits — verified live
/// 2026-08-01, it left every display list within a second of a `kill -9`. That is
/// why `lidless.sh` cannot own this feature: a shell command would create the
/// display, disable the panel and then exit, undoing the display a millisecond
/// later. See docs/ARCHITECTURE.md
///
/// Note what this does NOT buy. The virtual display going away does not bring the
/// built-in back; the disable outlives the process (see `setDisplayEnabled`), so
/// a crash leaves the Mac with no real display until the watchdog or the rescue
/// tool acts. Do not read "alive for exactly as long as this object" as "a crash
/// tidies itself up".
///
/// Create ONE per lid cycle and never in a loop. Five creations and releases in
/// ten seconds on 2026-08-01 left the Mac with the built-in gone from all three
/// display lists, the panel dark, and no way in locally or remotely; it took the
/// power button.
/// The display's identity and whether it is still alive, shared between the
/// thread that builds it and the queue its termination handler runs on.
///
/// Both facts have to cross a thread boundary and neither is available when it is
/// needed. The handler is registered on the descriptor before the display exists,
/// so it cannot capture an ID; and the window server CAN terminate a display
/// between `initWithDescriptor:` and the line that reads its ID back — the
/// previous version assumed it could not, was an unsynchronised read/write pair
/// on top of that, and delivered `0` to a handler that then matched nothing.
///
/// So termination is recorded whether or not the ID is known yet. If it arrives
/// first, `publish` says so and the initialiser fails — which is the honest
/// outcome, and leaves the caller on a path that never touches the panel.
final class DisplayLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var identity: UInt32 = 0
    private var terminated = false

    /// Called from the termination handler. Returns the ID to report, or nil when
    /// the display died before anyone learned its ID — there is nothing to name,
    /// and `publish` will refuse instead.
    func noteTerminated() -> UInt32? {
        lock.lock()
        defer { lock.unlock() }
        terminated = true
        return identity == 0 ? nil : identity
    }

    /// Returns false if the display has already terminated.
    func publish(_ id: UInt32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !terminated else { return false }
        identity = id
        return true
    }

    var hasTerminated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminated
    }
}

final class VirtualDisplay {
    private let object: AnyObject
    private let queue: DispatchQueue
    private let lifecycle: DisplayLifecycle
    let displayID: UInt32

    /// Whether the window server has taken this display away. Synchronous and
    /// safe to read from anywhere, which is the point: a caller about to switch
    /// the built-in off needs to know this NOW, not whenever a callback lands.
    var hasTerminated: Bool { lifecycle.hasTerminated }

    /// - Parameters:
    ///   - maxPixelsWide/High: the panel's physical pixel dimensions, used only
    ///     as the descriptor's capability ceiling.
    ///   - modeWide/High: the dimensions of the single advertised mode. On arm64
    ///     these are the panel's physical pixels: with `hiDPI` set, WindowServer
    ///     halves them into points, matching the panel exactly. On Intel the same
    ///     API does not halve them, so these are instead the panel's current
    ///     logical dimensions. Supplying a 3072x1920 Intel panel's physical size
    ///     created a 3072x1920 1x workspace, larger than the real display.
    ///
    /// Note the display comes up at `backingScaleFactor` 1.0, not 2.0. Every
    /// combination of mode size, pixel cap and the hiDPI flag was tried on
    /// 2026-08-01 and none produced a 2x display; `hiDPI` is not inert (clearing
    /// it stops a 2940-wide mode activating at all), it simply does not control
    /// the backing scale. Documented in README as a real difference, not hidden.
    ///   - onTerminated: called on `queue`, with the display's own ID, if the
    ///     window server takes the display away by itself. That leaves the panel disabled with nothing carrying
    ///     the session, so the owner has to put it back immediately; without this
    ///     hook the first anyone would know is a black screen.
    init?(maxPixelsWide: UInt32, maxPixelsHigh: UInt32,
          modeWide: UInt32, modeHigh: UInt32,
          millimetresWide: Double, millimetresHigh: Double, refreshHz: Double,
          onTerminated: (@Sendable (UInt32) -> Void)? = nil) {
        guard case .available = DisplayAPI.support,
              let msgSendRaw = DisplayAPI.msgSend,
              let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let modeClass = NSClassFromString("CGVirtualDisplayMode"),
              let displayClass = NSClassFromString("CGVirtualDisplay") else { return nil }

        let alloc = unsafeBitCast(msgSendRaw, to: DisplayAPI.MsgSendAlloc.self)
        let initMode = unsafeBitCast(msgSendRaw, to: DisplayAPI.MsgSendInitMode.self)
        let initObj = unsafeBitCast(msgSendRaw, to: DisplayAPI.MsgSendInitObj.self)
        let apply = unsafeBitCast(msgSendRaw, to: DisplayAPI.MsgSendApply.self)
        let uint32 = unsafeBitCast(msgSendRaw, to: DisplayAPI.MsgSendUInt32.self)
        let voidObj = unsafeBitCast(msgSendRaw, to: DisplayAPI.MsgSendVoidObj.self)

        let descriptor = descriptorClass.init()
        // Deliberately NOT the panel's own vendor/product/serial. Cloning a real
        // display's EDID identity risks colliding with its colour profile and with
        // the display-preferences records macOS keys off that identity.
        descriptor.setValue("Lidless Virtual Display", forKey: "name")
        descriptor.setValue(NSNumber(value: LidlessVirtualDisplayIdentity.vendorID),
                            forKey: "vendorID")
        descriptor.setValue(NSNumber(value: LidlessVirtualDisplayIdentity.productID),
                            forKey: "productID")
        descriptor.setValue(NSNumber(value: LidlessVirtualDisplayIdentity.serialNumber),
                            forKey: "serialNum")
        descriptor.setValue(NSValue(size: NSSize(width: millimetresWide, height: millimetresHigh)),
                            forKey: "sizeInMillimeters")
        descriptor.setValue(NSNumber(value: maxPixelsWide), forKey: "maxPixelsWide")
        descriptor.setValue(NSNumber(value: maxPixelsHigh), forKey: "maxPixelsHigh")

        queue = DispatchQueue(label: "io.github.lidless.virtualdisplay")
        descriptor.setValue(queue, forKey: "queue")

        let lifecycle = DisplayLifecycle()
        self.lifecycle = lifecycle
        // Registered unconditionally, not only when a caller wants the callback:
        // `hasTerminated` promises to answer for any instance, and wiring it to
        // the caller's interest made that promise false for a display created
        // without one. The callback is what is optional, not the bookkeeping.
        let handler: @convention(block) () -> Void = {
            if let id = lifecycle.noteTerminated() { onTerminated?(id) }
        }
        voidObj(descriptor, sel_getUid("setTerminationHandler:"),
                unsafeBitCast(handler, to: AnyObject.self))

        guard let modeAlloc = alloc(modeClass, sel_getUid("alloc")),
              let mode = initMode(modeAlloc.takeUnretainedValue(),
                                  sel_getUid("initWithWidth:height:refreshRate:"),
                                  modeWide, modeHigh, refreshHz)?.takeRetainedValue()
        else { return nil }

        let settings = settingsClass.init()
        settings.setValue([mode] as NSArray, forKey: "modes")
        settings.setValue(NSNumber(value: UInt32(1)), forKey: "hiDPI")

        guard let displayAlloc = alloc(displayClass, sel_getUid("alloc")),
              let display = initObj(displayAlloc.takeUnretainedValue(),
                                    sel_getUid("initWithDescriptor:"),
                                    descriptor)?.takeRetainedValue()
        else { return nil }

        object = display
        guard apply(display, sel_getUid("applySettings:"), settings).boolValue else { return nil }
        displayID = uint32(display, sel_getUid("displayID"))
        guard displayID != 0 else { return nil }
        // Refuses if the window server already took it away during construction.
        // `display` is released with `self`, so nothing is left behind.
        guard lifecycle.publish(displayID) else { return nil }
    }

    /// Verified by polling the active list, never by the BOOL `applySettings:`
    /// returned — it reports that the settings were accepted, not that a display
    /// exists. Measured activation takes 30-60 ms; the timeout is for the case
    /// where the window server is busy, which does happen (a remote-desktop
    /// session establishing at the same moment made one attempt miss 3 seconds).
    /// The default matches `Lidless.panelWaitTimeout` (`Sources/main.swift`) and
    /// is duplicated rather than shared because this file must not import the
    /// app target — the rescue binary links it too. Change one, change both.
    func waitUntilActive(timeout: TimeInterval = 5.0) async -> Bool {
        await DisplayAPI.waitForActive(displayID, active: true, timeout: timeout)
    }
}
