// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Dmytro Udovychenko

import Foundation

// A tiny standalone helper for testing real interop between lidless.sh's
// lockf-based with_lock() and SystemProbe's native flock() call — a second
// process is required to exercise this for real (flock(2) locks are per-open
// file-description, so two opens in the SAME process, as ParserTests.swift
// already covers, cannot prove cross-process behavior). Not part of
// ParserTests.swift's `@main`, to keep that binary's normal run un-changed;
// compiled and invoked separately, only by the with_lock interop test in
// tests/run.sh. See docs/ARCHITECTURE.md (review
// round 1 asked for a true bidirectional test, not two same-language ones).
//
// Usage:
//   LockHelper acquire <path>            exit 0 if acquired (and release immediately), 1 if refused
//   LockHelper hold <path> <seconds>     acquire, print "held" once acquired (the caller's
//                                        readiness handshake, so it never has to guess how long
//                                        acquisition takes), sleep for <seconds>, then release.
@main
struct LockHelper {
    static func main() {
        let args: [String] = CommandLine.arguments
        guard args.count >= 3 else {
            writeError("usage: LockHelper acquire|hold <path> [seconds]\n")
            exit(64)
        }
        let mode: String = args[1]
        let path: String = args[2]
        switch mode {
        case "acquire":
            if let fd: Int32 = SystemProbe.acquireLock(path: path) {
                SystemProbe.releaseLock(fd)
                exit(0)
            } else {
                exit(1)
            }
        case "hold":
            guard args.count >= 4,
                  let seconds: Double = Double(args[3]),
                  seconds >= 0 else {
                writeError("usage: LockHelper hold <path> <non-negative-seconds>\n")
                exit(64)
            }
            guard let fd: Int32 = SystemProbe.acquireLock(path: path) else {
                print("refused")
                exit(1)
            }
            print("held")
            fflush(stdout)
            Thread.sleep(forTimeInterval: seconds)
            SystemProbe.releaseLock(fd)
            exit(0)
        default:
            exit(64)
        }
    }

    private static func writeError(_ message: String) {
        guard let data: Data = message.data(using: .utf8) else {
            return
        }
        FileHandle.standardError.write(data)
    }
}
