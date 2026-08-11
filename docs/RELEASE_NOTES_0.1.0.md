# Lidless 0.1.0

The first public release of Lidless keeps a MacBook awake and reachable for
remote desktop or coding agents while its lid is closed, without requiring an
external monitor.

## Highlights

- Native macOS status window and menu bar controls.
- Closed-lid keep-awake behavior with a shared command-line interface.
- Optional Low Power Mode, screen-lock relaxation and automatic shutdown.
- Built-in display blackout with an independent recovery watchdog.
- Battery, power, temperature and fan telemetry where supported.
- Universal `arm64` and `x86_64` application bundle.

## Install

Download both release assets and verify them in Terminal:

```bash
cd ~/Downloads
shasum -a 256 -c Lidless-0.1.0-macos-universal.zip.sha256
```

Move `Lidless.app` to `/Applications`, try to open it once, then use
**System Settings → Privacy & Security → Open Anyway**. Lidless is ad-hoc signed
and not notarized, so macOS requires this manual approval.

For a verified official release, the Terminal alternative is:

```bash
xattr -dr com.apple.quarantine /Applications/Lidless.app
open /Applications/Lidless.app
```

## Safety

Lidless changes the persistent system-wide `pmset disablesleep` setting. Press
**Disable** before putting the Mac in a bag. Rebooting or deleting Lidless does
not reset that setting; the manual recovery command is:

```bash
sudo pmset -a disablesleep 0
```

Requires macOS 13 or newer. Primary real-hardware validation was performed on
an M4 MacBook Air running macOS 26.6. This build is ad-hoc signed and is not
notarized with Apple.
