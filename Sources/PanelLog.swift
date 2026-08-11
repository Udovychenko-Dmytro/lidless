// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Dmytro Udovychenko

import Foundation
import os

/// Panel blackout's flight recorder, written to two places at once.
///
/// The feature made a Mac unusable twice on 2026-08-03 and neither occurrence
/// could be explained afterwards, because the app wrote nothing anywhere at all —
/// `log show --predicate 'processImagePath CONTAINS "Lidless"'` came back empty
/// while the panel sat dark. Every conclusion had to be inferred from what OTHER
/// processes happened to log nearby, and that is how a wrong cause (a filtering
/// event tap belonging to a mouse driver) survived a whole investigation before
/// being disproved.
///
/// **The unified log**, subsystem `io.github.lidless`:
///
///     log show --last 30m --predicate 'subsystem == "io.github.lidless"' --style compact
///
/// Every value is interpolated `.public` on purpose. `os_log` redacts
/// interpolated values by default, and a recording that reads
/// `restore failed: <private>` is worth no more than the empty log it replaced.
/// Nothing recorded here is a secret: display IDs, lid state and brightness
/// levels are all readable from `ioreg` by any process on the machine anyway.
/// Nothing user-identifying is passed in, and call sites must keep it that way.
///
/// Levels are chosen for what survives to disk, not for how they read. Only
/// `.notice` and above are persisted; `.info` and `.debug` are dropped unless
/// something is streaming at that moment, and nothing is streaming when this
/// fails — the failure is found minutes later by someone who cannot see the
/// screen. So there is no debug level here, and volume is held down the only way
/// then left: by recording transitions rather than ticks, and the periodic state
/// line only while the panel is actually held.
///
/// **A plain text file**, `lidless-panel.log`, next to the `.app` bundle — see
/// `FileSink.resolvePath`. The unified log already survives a reboot, but reading
/// it needs a terminal and a predicate; this one can be opened by double-clicking
/// it, which matters when the machine that failed is the machine you are trying
/// to investigate from.
enum PanelLog {
    /// The predicate to filter on. Matches the bundle identifier, so the app's
    /// own lines and nothing else.
    static let subsystem: String = "io.github.lidless"

    /// Base name of the text file. Also referenced from `docs/ARCHITECTURE.md` §11.
    static let fileName: String = "lidless-panel.log"

    private static let log = Logger(subsystem: subsystem, category: "panel")
    private static let sink = FileSink()

    /// Where the text file actually ended up, or `nil` if neither location could
    /// be opened. Worth surfacing rather than assuming: the fallback path is not
    /// the one most people will look in.
    static var filePath: String? { sink.path }

    /// Something happened that a later investigation will want to place on a
    /// timeline: a blackout armed, a restore attempted, a goal changed, the lid
    /// moved.
    static func event(_ text: String) {
        log.notice("\(text, privacy: .public)")
        sink.write(level: "  ", text)
    }

    /// Something did not work. Persisted exactly like `event` — the split exists
    /// so a reader can ask for only the failures with
    /// `log show --predicate 'subsystem == "io.github.lidless" AND messageType == error'`,
    /// or `grep '!!' ` in the text file.
    static func failure(_ text: String) {
        log.error("\(text, privacy: .public)")
        sink.write(level: "!!", text)
    }
}

/// The text half of `PanelLog`.
///
/// `@unchecked Sendable` with an `NSLock` rather than an actor: the writes have
/// to be ORDERED and SYNCHRONOUS. An actor would make every call site `await`,
/// and worse, would let the process die with lines still queued — which is
/// precisely the case this exists to record. A lock and a blocking write cost
/// microseconds at this volume (twelve lines a minute while a blackout is held,
/// a handful otherwise) and leave nothing in flight.
private final class FileSink: @unchecked Sendable {
    /// Roll over at this size, keeping exactly one previous file. Blackout is a
    /// rare event and its lines are short, so this is months of history — but
    /// unbounded growth in a file nobody ever looks at is its own bug.
    private static let maxBytes: Int = 4 * 1024 * 1024

    private let lock = NSLock()
    private var handle: FileHandle?
    private var resolved: Bool = false
    private var resolvedPath: String?
    private var bytes: Int = 0

    private let stamp: DateFormatter = {
        let formatter = DateFormatter()
        // Local time, to match what `log show` prints by default — an
        // investigation that has to convert between two of its own artefacts
        // will eventually convert one of them wrong.
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// Resolves on demand rather than reporting `nil` until the first write.
    /// The launch line asks for this path in order to log it, so a lazy read here
    /// would answer "none" on the one line whose whole job is to say where the
    /// file is.
    var path: String? {
        lock.lock()
        defer { lock.unlock() }
        if !resolved { open() }
        return resolvedPath
    }

    func write(level: String, _ text: String) {
        lock.lock()
        defer { lock.unlock() }
        if !resolved { open() }
        guard let handle, let data = "\(stamp.string(from: Date())) \(level) \(text)\n"
            .data(using: .utf8) else { return }
        // `try?`, and deliberately silent: a logger that can throw its way into
        // the failure path it is recording is worse than one that misses a line.
        try? handle.write(contentsOf: data)
        // Flushed on every line. The subject of this recording is a Mac that has
        // to be hard-restarted, and a line still sitting in a buffer when the
        // power goes is a line that was never written.
        try? handle.synchronize()
        bytes += data.count
        if bytes >= Self.maxBytes { rollOver() }
    }

    /// Beside the `.app` first, because that is where somebody testing a local
    /// build will look for it. `~/Library/Logs/Lidless/` second.
    ///
    /// This comment used to add that an app moved into `/Applications` "could not
    /// anyway" write beside itself. That is false on a stock Mac: `/Applications`
    /// is `drwxrwxr-x root:admin`, so the containing directory is writable by the
    /// admin user — and by anything running as them. The beside-the-bundle
    /// candidate is therefore a path another local process can pre-create, which
    /// is why `openExclusivelyOwned` and not `createFile` does the opening.
    private func resolvePath() -> [String] {
        var candidates: [String] = []
        let bundle: URL = Bundle.main.bundleURL
        // `bundleURL` is the `.app` for a bundled build and the containing
        // directory for a bare executable, so only step up when it really is a
        // bundle — otherwise this writes one level above the binary.
        let beside: URL = bundle.pathExtension == "app"
            ? bundle.deletingLastPathComponent()
            : bundle
        candidates.append(beside.appendingPathComponent(PanelLog.fileName).path)
        // `HOME` first, `NSHomeDirectory()` second. They agree in every real run;
        // they differ under a test harness, because `NSHomeDirectory()` reads
        // getpwuid and ignores the environment entirely — measured 2026-08-06,
        // which is why the fallback could not be exercised without this. The rest
        // of the project already resolves the home directory this way
        // (`lidless.sh` uses `$HOME`; `DisplayRescue` has `LIDLESS_TEST_HOME`).
        let home: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        candidates.append(home + "/Library/Logs/Lidless/" + PanelLog.fileName)
        return candidates
    }

    /// Sets `resolved` itself — including when every candidate fails, so a Mac
    /// where neither location can be written stops trying rather than attempting
    /// two `createFile` calls per line for the rest of the session.
    private func open() {
        resolved = true
        let manager = FileManager.default
        for candidate in resolvePath() {
            let directory = (candidate as NSString).deletingLastPathComponent
            try? manager.createDirectory(
                atPath: directory, withIntermediateDirectories: true
            )
            guard let (opened, size) = Self.openExclusivelyOwned(candidate) else { continue }
            handle = opened
            resolvedPath = candidate
            bytes = size
            // Announced to the unified log, not to the file: a reader who has
            // only one of the two artefacts needs to be told where the other one
            // is, and this is the direction that works.
            Logger(subsystem: PanelLog.subsystem, category: "panel")
                .notice("panel log file: \(candidate, privacy: .public)")
            return
        }
    }

    /// Opens a candidate for appending, refusing anything that is not a plain
    /// file this user already owns, and returns its current size.
    ///
    /// `O_NOFOLLOW` is the point. Both candidate directories can be writable by
    /// another local process (see `resolvePath`), and `FileManager.createFile` /
    /// `FileHandle(forWritingTo:)` — what this used to do — follow a symlink
    /// planted at the target, which would let someone redirect this app's own
    /// writes into any file the user can write. The `st_uid` check covers the
    /// other half: a plain file created by somebody else first, which they would
    /// then be able to read.
    ///
    /// `O_APPEND` rather than seek-to-end, so the offset cannot be stale.
    /// Failure is `nil`, not a thrown error: the caller's whole contract is to
    /// try the next candidate and never to interrupt what it is recording.
    ///
    /// `O_NONBLOCK` is not decoration. `open(2)` on a FIFO with `O_WRONLY` blocks
    /// until a reader appears, so a named pipe planted at either candidate would
    /// park this call — on the main thread, at the first log line — for as long as
    /// the attacker liked. Caught by the FIFO case in `tests/run.sh` hanging the
    /// whole suite, 2026-08-06. It is cleared again below, because for the regular
    /// file this ends up with it means nothing and leaving it set would be a
    /// surprise to any later reader of `handle`.
    private static func openExclusivelyOwned(_ path: String) -> (FileHandle, Int)? {
        let descriptor = Darwin.open(
            path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_NONBLOCK, 0o600
        )
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              fcntl(descriptor, F_SETFL, O_WRONLY | O_APPEND) != -1
        else {
            Darwin.close(descriptor)
            return nil
        }
        return (FileHandle(fileDescriptor: descriptor, closeOnDealloc: true), Int(info.st_size))
    }

    private func rollOver() {
        guard let current = resolvedPath else { return }
        let previous = current + ".1"
        try? handle?.close()
        handle = nil
        let manager = FileManager.default
        try? manager.removeItem(atPath: previous)
        try? manager.moveItem(atPath: current, toPath: previous)
        // Reopened immediately rather than on the next line, so a rollover that
        // fails is visible as a file that stopped growing rather than as one
        // that silently swallowed everything after it. `open()` owns `resolved`,
        // so there is no flag to set here — an earlier version cleared it and let
        // `open()` run twice, leaking the first handle.
        open()
    }
}
