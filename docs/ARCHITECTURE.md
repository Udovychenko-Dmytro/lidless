# Lidless architecture and safety invariants

Lidless has two front ends over the same system mechanisms: a native SwiftUI app
and `lidless.sh`. They share preferences in the `io.github.lidless` defaults
domain and runtime markers in the user's home directory.

## Core session

Enabling Lidless starts a tracked `caffeinate` process and sets
`pmset disablesleep 1`. Disabling reverses the persistent power setting before
discarding the tracked state. Every privileged change is verified by reading the
system value back; a successful process exit alone is never proof of success.

Enable and Disable share an operation lock so the GUI, CLI and watchdog cannot
race. State files are consumed only after their associated restore operation has
been verified.

## Privileged boundary

The optional installer places an argument-free shutdown helper in
`/Library/PrivilegedHelperTools` and an exact sudoers rule in `/etc/sudoers.d`.
The installed helper cannot accept caller-controlled arguments. The installer
checks the helper against the SHA-256 manifest sealed inside the app before the
first privileged write.

## Automatic shutdown

Time and battery limits use a 60-second cancellable grace period. Screen-lock
restore state blocks unattended shutdown because `sysadminctl` requires an
interactive account password. Low Power Mode is restored before shutdown; a
failed restore is reported but does not turn repeated polling into a tight loop.

## Display blackout and recovery

Virtual-display mode creates a temporary display and disables the built-in
panel. Dim mode leaves the display topology unchanged and lowers brightness.
Neither mode starts unless the independent rescue watchdog is alive. A marker
and heartbeat let the rescue process distinguish a healthy owner from a dead or
hung app. Recovery is deliberately one-way: it may reveal displays and raise
brightness, but never hides a display.

The display APIs are private and may change in a macOS update. Missing or
ambiguous probes disable the feature instead of guessing.

## Probe policy

System probes have deadlines and every missing reading is representable. An
unknown value is never silently converted into a safe or healthy state. SMC
sampling is serialized because the underlying call has no cancellable timeout;
the display rescue binary intentionally does not link the SMC sampler.
