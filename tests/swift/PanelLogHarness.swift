// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Dmytro Udovychenko

import Foundation

// Drives Sources/PanelLog.swift as a separate process, because that file is not
// part of the parser test binary (tests/run.sh compiles only SystemProbe.swift +
// SMCSensors.swift + ParserTests.swift) and its sink is private to it.
//
// Same shape as tests/swift/LockHelper.swift: compiled on demand by tests/run.sh,
// prints one machine-readable line and exits. The line is the path PanelLog
// actually opened, or `none` if it opened nothing — which is what the symlink
// case asserts on.
//
// `bundleURL` for a bare executable is the directory holding it, so the
// "beside the .app" candidate is simply this binary's own directory. That is
// what lets the test plant a symlink at the first candidate without an .app.
@main
enum PanelLogHarness {
    static func main() {
        PanelLog.event("harness line")
        print(PanelLog.filePath ?? "none")
    }
}
