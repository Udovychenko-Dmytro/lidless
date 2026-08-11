# What the SMC exposes

Measured on 2026-08-05 on the M4 Air (10 cores, `Apple M4`, macOS 26.6), to
answer whether Lidless could show power draw, fan speed and temperatures the way
iStat Menus does. This file exists so the measurements do not have to be
repeated.

**Implemented 2026-08-05.** `Sources/SMCSensors.swift` reads these keys —
`SMCDecode` is the pure decoder, `SMCConnection` the IOKit half — and the
readings appear as a strip under the status band in the window and as rows in
the menu bar popover (`Sources/main.swift`, `sensorStrip` and `MenuBarPanel`).
The AC-drain finding in §4 is a separate `ioreg` probe in
`Sources/SystemProbe.swift` (`batteryDrainResult`).

**There was never a `docs/plans/SENSOR_STRIP_PLAN.md`.** Eight places in the
code cited it by phase and section; it is in no commit and no worktree
(`git log --all` finds nothing). The sensor strip was built without a written
plan, and this file — measurements first, rules second — is the whole of the
rationale that exists. The citations were rewritten to point here on
2026-08-06; if a phase number appears in an old comment somewhere, it refers to
nothing.

Everything below is a reading taken from a live probe. Where a claim is
inference rather than measurement it says so.

---

## 1. The SMC is readable without root

`IOServiceOpen` on the `AppleSMC` service succeeds with ordinary user
privileges. The keyed interface (`IOConnectCallStructMethod`, selector 2)
enumerates **2130 keys, of which 2091 read back**.

This is the finding that decides the design. The obvious alternative,
`powermetrics`, needs root, and using it would have meant widening the installed
sudoers rule (`README.md`, "Powering off needs root") to get a status readout.
That trade is not necessary.

### The struct layout is the trap

The request/response struct must be **exactly 80 bytes**. A direct Swift
translation of the usual C definition comes out at **76**, because Swift does not
add the tail padding that C puts after the `keyInfo` member's trailing `UInt8`.
Every call then fails with `kIOReturnBadArgument` (`0xE00002C2`), and — this is
the part that wastes an afternoon — a failed call is indistinguishable from an
absent key, so the whole machine looks like it has no power sensors at all. The
first pass of this investigation concluded exactly that, wrongly.

Pad `keyInfo` to 12 bytes explicitly and assert `MemoryLayout<KeyData>.stride ==
80` before opening the connection.

## 2. The sensor map

Labelled by loading one engine at a time and seeing which keys moved. CPU load
was 12 threads at `.userInteractive` QoS; GPU load was a Metal compute kernel.
Each phase was measured against a baseline taken only after `PSTR` had actually
settled, not after a fixed sleep — see §5.

| Keys | What it is | Evidence |
| --- | --- | --- |
| `Tp*` (39) | **CPU** core temperatures | +45.3 °C under CPU load, +6.7 under GPU |
| `Tg*` (18) | **GPU** temperatures | +31.1 °C under GPU load, +6.7 at the CPU sensors during it |
| `TB0T` `TB1T` `TB2T` | **Battery** temperature (3 sensors) | flat under both loads (+0.1) |
| `PSTR` | total power, watts | 2.94 → 21.15 W under CPU load |
| `PDTR` | total power, tracks `PSTR` | 3.43 → 21.07 W — but see §5 |
| `PZC0` `PZC1` `PHPS` | CPU cluster power | +15.2 W under CPU load, +1.4 under GPU |
| `PPBR` `Pb0f` | battery rail power | cross-checked against `ioreg`, §4 |

All of the above are type `flt ` — IEEE floats, no decoding ambiguity. That
matters, because the integer types are not safe (§5).

`flt ` is **little-endian**, and the integer keys are big-endian. Stated
explicitly on 2026-08-05 because the first draft of the implementation plan
guessed the opposite way round: every figure above was produced by a probe that
loaded the four bytes natively on arm64, which is little-endian, and a
big-endian read of the same bytes would have been garbage rather than a
believable 3.6 W idle. The two orders disagreeing within one interface is the
same inconsistency §5 is about.

`Tg*` also rises under CPU load (+28.3), so it is not selective in that
direction. That does not weaken the mapping: under *GPU* load the CPU sensors
stayed at +6.7 while `Tg*` went to +31.1. The asymmetry is heat spreading across
a shared die in a fanless chassis — inference, but the only reading consistent
with both runs.

The battery sensors are the control in this experiment. They stay flat when
something is supposed to stay flat, which is what makes the other two columns
trustworthy.

## 3. Fan keys must be matched by role, not prefix

The original M4 Air measurement exposed no `F*` keys, as expected for a fanless
machine. Testing on a Mac16,5 MacBook Pro later exposed the flaw in treating
every `F*` key as a live fan speed: the family also contains minimum, maximum
and target speeds. Taking the maximum across the entire family displayed
roughly **5777 rpm** while the fan was stopped — the hardware capability, not a
measurement.

Only `F?Ac` is an actual-speed key (`?` is the fan index). `F?Mn`, `F?Mx`,
`F?Tg` and metadata such as `FNum` must not enter the reading. A valid `F?Ac`
value of zero means the fan is stopped and is rendered as `0 rpm`; an absent
actual-speed key means the machine exposes no fan reading and renders **No
Data** after sampling.

## 4. Battery rail power, cross-checked

`PPBR` was validated against an independent source rather than assumed.
`ioreg -rn AppleSmartBattery` reported `InstantAmperage` of −820 mA at 12.59 V,
which is 10.3 W; `PPBR` read 10.6 W in the same moment. Agreement within noise.

Note `InstantAmperage` is returned **unsigned**: a discharge of −820 mA arrives
as `18446744073709550796`. Subtract 2^64 when the value exceeds 2^63.

The reading that prompted this check is worth keeping: under load the Mac was
**discharging the battery while connected to AC**, with `IsCharging = No`. The
35 W adapter could not cover a 21 W SoC plus the rest of the machine. For a
laptop left plugged in for days as a remote-desktop host, "on AC and still
draining" is a state worth surfacing.

### 4a. The charge figure updates slowly, and no SMC key fixes that

Measured 2026-08-05, because the Charge chip was reported as hanging while the
rest of the strip moved:

- **`InstantAmperage` is a slow register.** Sampled once a second for 45 seconds
  of steady charging it changed **once** (2028 → 1995 mA). Over a longer window
  it moves every 20–45 s. The app polls it every 5 s and shows every change it
  sees — the lag is in the gauge, not in the polling.
- **`PPBR` is not the charge power.** It read **1.30 W** while the battery was
  taking 1999 mA at 12.7 V — about 25 W — and barely moved under load. The §4
  cross-check above was taken while **discharging**, and it does not generalise
  to charging. Do not use it as the magnitude for a Charge reading.
- **`TVA0` and `mxA0` are the adapter's negotiated capability, not a
  measurement.** Both sat at exactly 26.06 W through idle, an eight-core load,
  and back — while `PSTR` moved 5.9 → 10.1 W underneath them. `TVA0` was found
  by scanning every `flt ` key for one near the live charge power, and it
  matched by coincidence at that instant. A key that agrees once is not a
  source; move the load and see whether it follows.

The conclusion is negative and worth keeping: on this Mac the direction and
magnitude of battery charge are only available from `ioreg`, at `ioreg`'s
cadence. The chip is as fast as the number behind it.

## 5. Three things that will produce wrong numbers

**Integer keys have inconsistent byte order.** `B0RM` reads 3872 big-endian and
matches `AppleRawCurrentCapacity` exactly. `B0AV` reads 51761 big-endian, which
is nonsense; byte-swapped it is 12746, matching `Voltage` from `ioreg`. Do not
assume an endianness for `ui16`. Apple Silicon sensor values are `flt `; the
Intel temperature and fan formats are handled separately below because their
fixed-point encodings and byte order are known. Other integer values remain
unsupported rather than guessed.

**A stale sample can be served.** In the first run `PSTR` at sample N equalled
`PDTR` at sample N−1, consistently. Reading the same key twice in a row returned
identical values, so the lag was between keys rather than within one. This was
**not reproduced** in later runs, and `PDTR` separately spent one run pinned at
exactly `0.00` before recovering. Cause unknown. Treat a reading of exactly zero
from a power key as "no data" rather than "no power", and discard the first read
after an idle gap.

**Low Power Mode halves everything.** The same load measured 6.49 W and a peak
`Tp*` of 62.6 °C with `lowpowermode 1`, and 21.15 W and 112.8 °C with it off —
the same binary, the same thread count, a threefold difference in power. Lidless
ships `lowPowerWhileActive` and holds LPM for the whole session when it is on, so a
sensor strip in this app will normally read *low* compared to any third-party
monitor running on the same machine. That is correct behaviour being reported
accurately, but it will look like a bug unless the UI says so.

## 5a. A read is fast; getting it scheduled is not

Measured on the M4 Max, from a plain command-line binary running the shipped
`SMCConnection.read()`:

```
read 1: 0.705s   <- opens the connection and enumerates the keys
read 2: 0.076s
read 3: 0.077s   <- and so on, ~80 ms thereafter
```

Inside the app the same call took **2.5–2.8 s** for the first sample after
launch, and over **ten seconds** while it was dispatched at `.background` QoS.
None of that is the SMC. Background is the one QoS tier macOS is free to defer
indefinitely, and on Apple Silicon it also pins the work to E-cores; at launch,
with the main thread busy and the `.utility` probes running, the sampling thread
simply did not get scheduled. The sampler is `.utility` now, like every other
detached probe in the app.

This matters because `sampleSensors()` abandons the strip permanently when a
sample overruns `sensorAbandonAfter`, and it was measuring wall clock from
dispatch — so scheduling delay, not a wedged kernel, is what it actually caught.
Twice. The deadline is now a minute, and two flags set on the sampling thread
(`SensorSampleProgress`) keep a blocked main actor or an unscheduled task from
reaching that clock at all. An abandon, and any sample over a second, is written
to the panel log; before that the failure was invisible except as "Sensors
stopped responding" on screen.

## 6. Not established

**Charging power, from the SMC.** Never observed, because the battery never
charged during testing: macOS optimised charging held it at 85 % with a small
negative current and `IsCharging = No` throughout. The `CH*` and `AC*` key
families exist in bulk — hundreds of keys — but assigning one to charge power
without seeing a real charge cycle would be a guess. Measuring it needs
optimised charging switched off, or the battery drained below the hold
threshold.

The shipped Charge chip therefore **does not read the SMC at all.** It is
`InstantAmperage × Voltage` from the same `ioreg` read as §4, which is the exact
arithmetic that was cross-checked against the SMC's own `PPBR` there (−820 mA ×
12.59 V = 10.3 W against 10.6 W). That validates the discharge direction; the
charge direction is the same formula with the sign the current carries, and it
still has not been seen against real hardware. It is also why the chip reports
direction at all: the SMC's battery-rail keys give a magnitude without one.

**Which CPU key is which core.** Broad `Tp*` matching was tested and rejected on
the Mac16,5 M4 Max. It exposed far more keys than physical cores, including
floats that fell to 1.5–1.9 at idle; averaging the family produced 31 °C while
iStat Menus showed 44 °C. A second key-by-key pass on 2026-08-05 also disproved
the first attempted M4 map: `Tp01`/`05`/`09`/`0D`/`0b`/`0e` returned 1.5–1.9,
`Tp0Y` returned zero, and `Tp0V` was absent on Mac16,5. The stable map on this
machine is `Tp0H`/`Tp0L`/`Tp0P`, plus `Te05` and `Te0S`; each E-cluster value is
weighted twice because it represents two of the four efficiency cores. These
are treated as domains, not claimed as one sensor per physical core. Known
M1–M3 maps are selected by chip generation; an unknown generation retains the
broad-family average only as a fallback. GPU and battery still use the maximum
of their groups.

**Intel uses different sensor names and encodings.** On the MacBookPro16,1 the
CPU cores are `TC1C`…`TC8C` and the discrete GPU die is `TGDD`; `TC0P`, `TG0P`
and `TG1P` are proximity sensors and should not be the primary readings because
they track the same surrounding heat. The app averages the available `TC?C`
cores, prefers `TGDD` for the GPU, and uses package/proximity keys only as
fallbacks for other Intel models. Temperatures use the `sp78` signed 7.8
fixed-point type, while Intel fan speeds may use unsigned 14.2 fixed-point
`fpe2`. Apple Silicon uses the `Tp*`/`Tg*` key families and `flt ` values
described above. The reader accepts only these known key/type combinations and
still hides a row rather than showing an unverified value.
