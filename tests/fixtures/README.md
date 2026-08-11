# Fixtures

Command output the parsers are tested against. Where a fixture came from matters
— a synthetic one only proves the parser handles what its author imagined.

All captured output is sanitized before publication. Hardware serial numbers,
session UUIDs and manufacturer-specific raw identity fields are replaced with
synthetic values, and tests must never depend on them.

| File | Provenance |
| --- | --- |
| `pmset-custom-macbook.txt` | Real, MacBook (Apple Silicon), macOS 26.5.2. `lowpowermode` edited back to the stock `AC 0 / battery 1`; the capture machine had it on. The asymmetry is deliberate — it makes a section mix-up visible. |
| `pmset-custom-sequoia.txt` | Real, MacBook Pro (M4 Max), macOS 15.7.7. This macOS calls the setting **`powermode`**, not `lowpowermode` — same value, other name, and reading only the newer name made every Low Power Mode reading on this machine "unknown". AC edited to 0 for the same section-mix-up asymmetry as above; the capture had both at 1. |
| `pmset-custom-macmini.txt` | **Synthetic.** No desktop Mac was available. Models the one thing that matters: no `Battery Power:` section at all. |
| `pmset-custom-ac-first.txt` | **Synthetic.** Same data as the MacBook capture with the sections swapped, to pin that order is not assumed. |
| `pmset-g-sleepdisabled-on.txt` | Real, captured with Lidless on. Note the columns are **tab**-separated — `pmset -g custom` uses spaces, and a parser that splits on `" "` misreads this one. |
| `pmset-g-sleepdisabled-off.txt` | **Synthetic.** |
| `pmset-ps-ac.txt` | Real, on AC at 85%. |
| `pmset-ps-battery.txt` | **Synthetic**, discharging at 18%. |
| `pmset-ps-desktop.txt` | **Synthetic**, no battery line. |
| `ioreg-clamshell-macbook.txt` | Real, 18 KB, lid open. Size is the point: `ioreg \| grep -q` dies of SIGPIPE on it. |
| `ioreg-desktop.txt` | Empty, which is exactly what the real command prints when no device has the key. |
| `ioreg-battery-ac-holding.txt` | Sanitized real capture, `ioreg -rn AppleSmartBattery`, 2026-08-05: on AC, `IsCharging = No`, `InstantAmperage = 0`. The ordinary plugged-in state, and the one a naive "not charging means draining" check gets wrong. Also carries measured `AdapterDetails` (35 W, cross-checked against `pmset -g adapter`) **and** an `AppleRawAdapterDetails` with a `Watts` of its own — which is what the adapter parser's anchoring test needs. |
| `ioreg-battery-ac-draining.txt` | **Synthetic**, one line changed from the capture above: `InstantAmperage = 18446744073709550796`, which is 2^64 − 820 — how a −820 mA discharge is actually reported. That figure was measured (docs/SMC_SENSORS.md §4), the file was not. |
| `ioreg-battery-charging.txt` | **Synthetic**, two lines changed: charging at +1450 mA. Charging was never observed on the capture machine — optimised charging held it at 85 %. |
| `ioreg-battery-absent.txt` | Empty, same as `ioreg-desktop.txt`: what the command prints on a Mac with no battery. |
| `sysadminctl-*.txt` | Real format (the timestamped stderr prefix is genuine); the values are set per case. `sysadminctl-password-required.txt` is the refusal that still exits 0. |

Refreshing a real capture:

```bash
pmset -g custom > tests/fixtures/pmset-custom-macbook.txt
```
