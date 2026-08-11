// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Dmytro Udovychenko

import Foundation
import IOKit
import Darwin

/// Sensor readings from the SMC — system power, and CPU/GPU/battery
/// temperature.
///
/// This file is deliberately NOT part of `SystemProbe.swift`, and deliberately
/// NOT compiled into `lidless-display-rescue`. Two separate reasons:
///
/// 1. The rescue tool's whole job is to work when the app is the thing that
///    died. Giving it an IOKit dependency it never calls is pure downside.
/// 2. Every probe in `SystemProbe` is a subprocess behind `Shell.defaultTimeout`
///    (`SystemProbe.swift:24`), and that timeout exists because on 2026-08-02
///    one `ioreg` that never returned wedged the whole refresh — see the file
///    header there. An in-process `IOConnectCallStructMethod` has no such
///    deadline and **cannot be killed**, so it must never share a code path
///    with the snapshot the blackout reconcile and the recovery heartbeat
///    depend on.
///
/// The measured spec for everything here is `docs/SMC_SENSORS.md`, taken on the
/// M4 Air on 2026-08-05. Key names, decode traps and failure modes come from
/// that document and are not re-derived here.
///
/// The file is split the way every probe in this project is split: a pure,
/// directly testable decoder, and an impure fetcher that is not unit-tested —
/// the same division as `screenLock()` vs `screenLock(in:)`.

// MARK: - Raw key values

/// One raw SMC key response as the driver hands it back: the four-character
/// type, the byte count the driver declared, and the data bytes themselves.
///
/// `bytes` is what the driver actually returned; `size` is what it said it
/// would return. They are kept separate on purpose, so the decoder can reject a
/// response whose declared length disagrees with the type it claims to be
/// rather than reading whatever happens to sit in the buffer.
struct SMCKeyValue: Sendable, Equatable {
    let type: String
    let size: Int
    let bytes: [UInt8]

    init(type: String, size: Int, bytes: [UInt8]) {
        self.type = type
        self.size = size
        self.bytes = bytes
    }

    /// Convenience for the common case where the declared size and the actual
    /// byte count agree.
    init(type: String, bytes: [UInt8]) {
        self.init(type: type, size: bytes.count, bytes: bytes)
    }
}

/// What a key is about. Only the groups this app shows — the SMC exposes 2130
/// keys on this Mac and the overwhelming majority are irrelevant here.
enum SMCGroup: Sendable, Equatable {
    case cpuTemp
    case gpuTemp
    case batteryTemp
    case systemPower
    case fanSpeed
}

// MARK: - Decoding (pure)

enum SMCDecode {
    /// The IEEE-754 single-precision format used for sensor values on Apple
    /// Silicon.
    static let floatType = "flt "

    /// The signed 7.8 fixed-point format used for temperature values by the
    /// Intel SMC. The SMC sends its two bytes most-significant first.
    static let signedFixed78Type = "sp78"

    /// The unsigned 14.2 fixed-point format used for Intel fan speeds. The
    /// SMC sends its two bytes most-significant first.
    static let unsignedFixedPE2Type = "fpe2"

    /// Plausible system power, in watts. **Chosen, not measured**
    /// (`docs/ARCHITECTURE.md` §9): the measured span on the M4 Air was 1.3–23.6 W,
    /// and the ceiling is headroom for larger Macs rather than an observed
    /// limit. The floor sits above zero deliberately — see `watts(_:)`.
    static let plausibleWatts: ClosedRange<Double> = 0.1...200

    /// Plausible die temperature, in °C. **Chosen, not measured**
    /// (`docs/ARCHITECTURE.md` §9). The measured peak was 112.8 °C under an all-core
    /// load with Low Power Mode off (`docs/SMC_SENSORS.md` §5), so the ceiling
    /// has headroom while still rejecting a garbage decode.
    static let plausibleCelsius: ClosedRange<Double> = 1...125

    /// Plausible fan speed, in rpm. Zero is a real reading: modern Macs stop
    /// their fans completely at low load. A missing fan is represented by an
    /// absent `F?Ac` key, not by coercing a returned zero to no-data.
    static let plausibleRPM: ClosedRange<Double> = 0...12000

    /// Decodes a `flt ` value, refusing anything it cannot vouch for.
    ///
    /// `flt ` is **little-endian**, unlike the big-endian integer keys. That is
    /// not a guess: the probe that produced every figure in
    /// `docs/SMC_SENSORS.md` loaded these four bytes natively on arm64 — little
    /// endian — and got plausible readings throughout, where a big-endian read
    /// of the same bytes would have been garbage rather than a believable 3.6 W
    /// idle.
    ///
    /// Returns nil for a wrong type, a wrong length, a non-finite value, or a
    /// value outside `plausible`. That last one is the important case: this
    /// feature's governing rule (`docs/SMC_SENSORS.md` §6) is that it must
    /// degrade to hiding a reading, never to showing a wrong one, and an
    /// out-of-range number is the shape a bad decode takes.
    static func float(_ value: SMCKeyValue, plausible: ClosedRange<Double>) -> Double? {
        guard value.type == floatType else { return nil }
        // Both the declared size and the delivered bytes must be a float's
        // worth. A driver that says "4 bytes" and hands back 2 is not a reading
        // to salvage.
        guard value.size == 4, value.bytes.count == 4 else { return nil }
        let bits: UInt32 = UInt32(value.bytes[0])
            | UInt32(value.bytes[1]) << 8
            | UInt32(value.bytes[2]) << 16
            | UInt32(value.bytes[3]) << 24
        let decoded = Double(Float(bitPattern: bits))
        guard decoded.isFinite else { return nil }
        guard plausible.contains(decoded) else { return nil }
        return decoded
    }

    /// System power in watts, with exactly 0.0 rejected as no-data.
    ///
    /// Zero is not a reading a running Mac can produce, and it is a shape the
    /// SMC demonstrably does produce when something is wrong: `PDTR` was
    /// observed pinned at exactly `0.00` for a whole measurement run before
    /// recovering, cause unknown (`docs/SMC_SENSORS.md` §5). Printing that as
    /// "0.0 W" would be a confident wrong number.
    ///
    /// The zero case is handled by `plausibleWatts` starting above zero rather
    /// than by a separate comparison, so there is one place to change it.
    static func watts(_ value: SMCKeyValue) -> Double? {
        float(value, plausible: plausibleWatts)
    }

    /// Die temperature in °C. Zero is rejected here for a different reason than
    /// in `watts(_:)`: a 0 °C die on a running Mac is not physically
    /// reachable, so a zero means the decode is wrong, not that the part is
    /// cold.
    static func celsius(_ value: SMCKeyValue) -> Double? {
        switch value.type {
        case floatType:
            return float(value, plausible: plausibleCelsius)
        case signedFixed78Type:
            return signedFixed78(value, plausible: plausibleCelsius)
        default:
            return nil
        }
    }

    /// Fan speed in rpm.
    static func rpm(_ value: SMCKeyValue) -> Double? {
        switch value.type {
        case floatType:
            return float(value, plausible: plausibleRPM)
        case unsignedFixedPE2Type:
            return unsignedFixedPE2(value, plausible: plausibleRPM)
        default:
            return nil
        }
    }

    /// Decodes an SMC `sp78`: a signed sixteen-bit integer with eight fraction
    /// bits, stored big-endian. This is deliberately temperature-only; other
    /// two-byte SMC values have inconsistent types and byte orders.
    private static func signedFixed78(
        _ value: SMCKeyValue,
        plausible: ClosedRange<Double>
    ) -> Double? {
        guard value.size == 2, value.bytes.count == 2 else { return nil }
        let bits = UInt16(value.bytes[0]) << 8 | UInt16(value.bytes[1])
        let decoded = Double(Int16(bitPattern: bits)) / 256
        guard decoded.isFinite, plausible.contains(decoded) else { return nil }
        return decoded
    }

    /// Decodes an SMC `fpe2`: an unsigned sixteen-bit integer with two
    /// fraction bits, stored big-endian. Intel Macs use it for `F?Ac`; Apple
    /// Silicon reports the same keys as `flt ` instead.
    private static func unsignedFixedPE2(
        _ value: SMCKeyValue,
        plausible: ClosedRange<Double>
    ) -> Double? {
        guard value.size == 2, value.bytes.count == 2 else { return nil }
        let bits = UInt16(value.bytes[0]) << 8 | UInt16(value.bytes[1])
        let decoded = Double(bits) / 4
        guard decoded.isFinite, plausible.contains(decoded) else { return nil }
        return decoded
    }

    /// The hottest reading in a group, or nil if nothing in it decoded.
    ///
    /// The maximum rather than the mean, because the 39 `Tp*` keys are
    /// collectively "the CPU" but which key is which P- or E-core was never
    /// established (`docs/SMC_SENSORS.md` §6). Averaging across an unknown mix
    /// of core types produces a number that is not any part's temperature; the
    /// maximum at least names something real — the hottest point measured.
    static func maxCelsius(_ values: [SMCKeyValue]) -> Double? {
        values.compactMap { celsius($0) }.max()
    }

    /// The arithmetic mean of every valid reading in a temperature group.
    ///
    /// CPU is presented as a representative package temperature rather than
    /// its hottest instantaneous point. This also matches the meaning users
    /// see in monitors that show a single aggregate CPU temperature. Invalid
    /// values are omitted instead of being allowed to pull the result toward
    /// zero; nil means that no member of the group decoded successfully.
    static func averageCelsius(_ values: [SMCKeyValue]) -> Double? {
        let decoded = values.compactMap { celsius($0) }
        guard !decoded.isEmpty else { return nil }
        return decoded.reduce(0, +) / Double(decoded.count)
    }

    /// A representative CPU temperature using the core/cluster keys for the
    /// detected Apple Silicon generation. Apple changes these undocumented
    /// names between generations, and broad `Tp*` matching is unsafe: on M4
    /// Max it also finds dozens of non-temperature values that fall to 1.5–1.9
    /// at idle and drag an average down into the low thirties.
    ///
    /// Repeated keys are intentional. M4 Max exposes two efficiency-cluster
    /// sensors for four E cores; each cluster is weighted twice. Its stable
    /// performance readings on Mac16,5 are the three Tp0H/Tp0L/Tp0P domain
    /// sensors. Other tempting M4 `Tp*` keys were measured returning 0–1.9 at
    /// idle and are not temperatures on that machine.
    static func cpuAverage(
        _ values: [(key: String, value: SMCKeyValue)],
        chipName: String?
    ) -> Double? {
        let byKey = Dictionary(uniqueKeysWithValues: values.map { ($0.key, $0.value) })
        let keys: [String]?
        switch chipName {
        case let name? where name.contains("Intel"):
            let cores = values
                .filter { isIntelCPUCoreKey($0.key) }
                .compactMap { celsius($0.value) }
            if !cores.isEmpty {
                return cores.reduce(0, +) / Double(cores.count)
            }
            // Older Intel models may expose only a filtered/raw package value
            // and a proximity sensor. Prefer package heat to chassis-adjacent
            // proximity; the latter is the last fallback because it closely
            // tracks GPU proximity and made both UI readings look identical.
            keys = ["TC0F", "TC0E", "TC0P"]
        case let name? where name.contains("M4"):
            keys = [
                "Te05", "Te05", "Te0S", "Te0S",
                "Tp0H", "Tp0L", "Tp0P"
            ]
        case let name? where name.contains("M3"):
            keys = [
                "Te05", "Te0L", "Te0P", "Te0S",
                "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
                "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"
            ]
        case let name? where name.contains("M2"):
            keys = [
                "Tp1h", "Tp1t", "Tp1p", "Tp1l",
                "Tp01", "Tp05", "Tp09", "Tp0D",
                "Tp0X", "Tp0b", "Tp0f", "Tp0j"
            ]
        case let name? where name.contains("M1"):
            keys = [
                "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D",
                "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"
            ]
        default:
            keys = nil
        }

        if let keys {
            if chipName?.contains("Intel") == true {
                return keys.lazy.compactMap { byKey[$0] }.compactMap { celsius($0) }.first
            } else {
                let decoded = keys.compactMap { byKey[$0] }.compactMap { celsius($0) }
                if !decoded.isEmpty {
                    return decoded.reduce(0, +) / Double(decoded.count)
                }
            }
        }
        return averageCelsius(values.map(\.value))
    }

    /// A representative GPU temperature. Intel Macs with a discrete GPU expose
    /// its actual die as `TGDD`; proximity values are deliberately fallbacks.
    /// Apple Silicon keeps using the hottest member of its measured `Tg*`
    /// family, where the exact per-block mapping is not established.
    static func gpuTemperature(
        _ values: [(key: String, value: SMCKeyValue)],
        chipName: String?
    ) -> Double? {
        if chipName?.contains("Intel") == true {
            let byKey = Dictionary(uniqueKeysWithValues: values.map { ($0.key, $0.value) })
            let preferred = ["TGDD", "TG0D", "TGDF", "TGDE", "TG0P", "TG1P"]
            if let reading = preferred.lazy
                .compactMap({ byKey[$0] })
                .compactMap({ celsius($0) })
                .first {
                return reading
            }
        }
        return maxCelsius(values.map(\.value))
    }

    /// Intel per-core temperature keys: `TC1C`, `TC2C`, and so on. Hexadecimal
    /// indices cover high-core-count models without accepting unrelated `TC*`
    /// package, proximity, maximum, or control values.
    private static func isIntelCPUCoreKey(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        guard bytes.count == 4,
              bytes[0] == Character("T").asciiValue,
              bytes[1] == Character("C").asciiValue,
              bytes[3] == Character("C").asciiValue else { return false }
        return (Character("0").asciiValue!...Character("9").asciiValue!).contains(bytes[2])
            || (Character("A").asciiValue!...Character("F").asciiValue!).contains(bytes[2])
    }

    /// Which group a key name belongs to, or nil for the ~2070 keys this app
    /// does not read.
    ///
    /// Prefix matching on the documented families (`docs/SMC_SENSORS.md` §2).
    /// `PSTR` is matched exactly rather than by a `P` prefix: the P family is
    /// enormous and includes per-rail keys that are not system totals. `PDTR`
    /// tracks `PSTR` but is deliberately excluded — it is the key that was seen
    /// pinned at exactly zero for a whole run.
    static func group(_ key: String) -> SMCGroup? {
        if key == "PSTR" { return .systemPower }
        if key.hasPrefix("Tp") || key.hasPrefix("Te") || key.hasPrefix("Tf")
            || isIntelCPUCoreKey(key) || ["TC0P", "TC0E", "TC0F"].contains(key) {
            return .cpuTemp
        }
        if key.hasPrefix("Tg")
            || ["TGDD", "TG0D", "TGDF", "TGDE", "TG0P", "TG1P"].contains(key) {
            return .gpuTemp
        }
        // The battery has three sensors on this Mac (TB0T/TB1T/TB2T) and they
        // tracked each other exactly, so the group is read the same way as the
        // others rather than special-casing a single key.
        if key.hasPrefix("TB") { return .batteryTemp }
        // Fan keys share a prefix but not a meaning: F0Ac is the actual speed,
        // while F0Mn/F0Mx/F0Tg are its minimum, maximum and target. Treating
        // all F* keys as readings made an idle fan display its ~5777 rpm
        // maximum. The middle character is the fan index; accept hexadecimal
        // indices so this is not artificially limited to ten fans.
        let bytes = Array(key.utf8)
        if bytes.count == 4,
           bytes[0] == Character("F").asciiValue,
           bytes[2] == Character("A").asciiValue,
           bytes[3] == Character("c").asciiValue,
           (Character("0").asciiValue!...Character("9").asciiValue!).contains(bytes[1])
               || (Character("A").asciiValue!...Character("F").asciiValue!).contains(bytes[1]) {
            return .fanSpeed
        }
        return nil
    }
}

// MARK: - Formatting (pure)

/// Formatting lives here, and is pure, because "0 W" where "—" belongs is
/// exactly the class of bug this feature must not ship. It is covered by tests
/// for that reason, and not because formatting is otherwise interesting.
enum SensorFormat {
    /// Returns nil — not a placeholder string — when there is nothing to show.
    /// The caller then renders nothing at all: a chip with no value is absent
    /// rather than empty (`docs/SMC_SENSORS.md` §6).
    static func watts(_ value: Double?) -> String? {
        guard let value: Double = value, value.isFinite else { return nil }
        guard SMCDecode.plausibleWatts.contains(value) else { return nil }
        return String(format: "%.1f W", value)
    }

    /// Whole degrees. Tenths are noise at this refresh rate and would make the
    /// strip twitch without telling anyone anything.
    static func celsius(_ value: Double?) -> String? {
        guard let value: Double = value, value.isFinite else { return nil }
        guard SMCDecode.plausibleCelsius.contains(value) else { return nil }
        return "\(Int(value.rounded())) °C"
    }

    static func rpm(_ value: Double?) -> String? {
        guard let value: Double = value, value.isFinite else { return nil }
        guard SMCDecode.plausibleRPM.contains(value) else { return nil }
        return "\(Int(value.rounded())) rpm"
    }

    /// The fan chip: a speed, or **No Data** once a sample has come back
    /// without one.
    ///
    /// A blank chip was the first attempt and it was wrong in practice: on a
    /// fanless Mac the column simply sat empty, which reads as a reading that
    /// failed rather than as a machine with no fan. A stopped fan is different:
    /// its actual-speed key returns zero, which is displayed as `0 rpm`.
    ///
    /// Before the first sample it is still nil, because "no fan" and "not
    /// asked yet" are different claims and only one of them is true then.
    static func fan(_ rpm: Double?, sampled: Bool) -> String? {
        if let text: String = self.rpm(rpm) { return text }
        return sampled ? "No Data" : nil
    }

    /// Two temperatures for one cell — the CPU's and the GPU's, sharing a chip.
    ///
    /// Both values carry a degree sign and neither spells out the scale:
    /// "CPU 51°  GPU 40°". A number with no unit at all is unreadable — that
    /// was the first thing anyone said about the bare CPU figure this cell
    /// shipped with. Two full "°C" do not fit: 141 pt against a 129.5 pt
    /// column, before the three-digit case. "51° 40°" is 117. The scale is
    /// named by the Battery chip beside it, which has the room for "33 °C".
    ///
    /// When only one of the two reads, it carries the full unit and the other
    /// slot is empty: alone in the chip it has the width, and nothing next to
    /// it to borrow the scale from.
    ///
    /// Returns nil when neither reads, so the caller draws no chip at all.
    static func temperaturePair(
        cpu: Double?,
        gpu: Double?
    ) -> (cpu: String, gpu: String?)? {
        let cpuText: String? = celsius(cpu)
        let gpuText: String? = celsius(gpu)
        switch (cpuText, gpuText) {
        case (nil, nil):
            return nil
        case let (.some(cpuText), nil):
            return (cpuText, nil)
        case let (nil, .some(gpuText)):
            // The GPU alone still belongs in the GPU's slot, so the CPU's slot
            // shows an em dash rather than sliding the GPU figure into it.
            return ("—", gpuText)
        case let (.some(cpuText), .some(gpuText)):
            return (degreesOnly(cpuText), degreesOnly(gpuText))
        }
    }

    /// Rewrites an already-formatted temperature as a bare degree: "51 °C" to
    /// "51°". Deliberately not a second number formatter: two of those would be
    /// two chances to round differently, and the pair would then disagree with
    /// itself.
    private static func degreesOnly(_ formatted: String) -> String {
        guard let space: String.Index = formatted.firstIndex(of: " ") else { return formatted }
        return String(formatted[formatted.startIndex..<space]) + "°"
    }

    /// The charge chip: what the battery rail is doing, as a label and a value.
    ///
    /// Signed input, unsigned output plus a label that names the direction —
    /// "Charge 18.3 W" and "Drain 10.3 W", not "Charge −10.3 W". A minus sign
    /// under a label saying "Charge" is a puzzle, and this chip sits next to
    /// four that all read left to right without one.
    ///
    /// **Zero is a value here, unlike everywhere else in this file.** A power
    /// key from the SMC reading exactly 0.0 means the decode failed
    /// (`docs/SMC_SENSORS.md` §5), but 0 mA out of `ioreg` is the ordinary,
    /// verified state of a full battery sitting on AC — it is the answer, not
    /// the absence of one. The chip is hidden by its caller when the probe did
    /// not read at all, which is a different thing and the flag on
    /// `SystemState.batteryDrainReadable` exists to tell them apart.
    ///
    /// Not part of the SMC strip's data, but formatted here because the chip it
    /// feeds sits in that strip and must be formatted the same way.
    /// `adapterWatts` is the adapter's rating, appended after the battery
    /// figure. Two numbers rather than one because they only mean something
    /// together: 10 W coming *out* of the battery is unremarkable until you
    /// know the brick supplying the machine is rated 35 W and is therefore
    /// losing (`docs/SMC_SENSORS.md` §4). Absent when nothing is plugged in,
    /// which is itself the answer.
    ///
    /// `hasBattery: false` — a Mac mini, a Studio, any desktop — reports **No
    /// Data** rather than rendering nothing. An empty chip there would look
    /// like a sensor that failed; the machine simply has no battery to report
    /// on, and saying so is shorter than leaving someone to work it out.
    static func charge(
        _ watts: Double?,
        adapterWatts: Int? = nil,
        hasBattery: Bool = true
    ) -> (label: String, value: String)? {
        guard hasBattery else { return ("Charge", "No Data") }
        guard let watts: Double = watts, watts.isFinite else { return nil }
        // Loose bound, and only to reject a decode gone wrong: no laptop rail
        // carries this, in either direction.
        guard abs(watts) < 500 else { return nil }
        let label: String = watts < 0 ? "Drain" : "Charge"
        var value: String = String(format: "%.1f W", abs(watts))
        // A rating of zero or an absurd one is no rating at all. The bound is
        // loose on purpose — Apple ships 140 W bricks, and a third-party dock
        // may report anything.
        if let adapterWatts: Int = adapterWatts, adapterWatts > 0, adapterWatts < 1000 {
            value += " · \(adapterWatts) W PSU"
        }
        return (label, value)
    }

    /// The one note the strip shows, or nil. Ordered by how much trouble the
    /// readings are in, which is the same rule the note panels in the window
    /// follow: only ever one line, and the worst applicable one.
    ///
    /// Pure, and shared by the window and the popover, so the two cannot drift
    /// into saying different things about the same readings.
    ///
    /// The Low Power Mode line was removed on request 2026-08-05. What it said
    /// is still true — Lidless holds Low Power Mode for the whole session when
    /// `lowPowerWhileActive` is set, and the same load measured 6.49 W with it on
    /// against 21.15 W with it off (`docs/SMC_SENSORS.md` §5) — so a strip
    /// reading a third of a third-party monitor's figure is accurate rather than
    /// broken. The mode is named in a tile directly above the strip, which is
    /// where that now has to be read from.
    ///
    /// `lowPowerActive` is kept in the signature deliberately: both call sites
    /// already have the value, and re-adding the note should not have to be an
    /// API change at two surfaces again.
    static func note(_ readings: SensorReadings, lowPowerActive: Bool) -> String? {
        // Both failure notes now name the remedy. Each state is one-way for the
        // life of the process — `Lidless.sensorsAbandoned` and
        // `SMCConnection.unavailable` are both set and never cleared — so
        // "relaunch" is not a suggestion, it is the only way back, and neither
        // string used to say it.
        if readings.abandoned {
            return "Sensors stopped responding — relaunch Lidless to try again"
        }
        // Distinguished from the line below it, which is a claim about the
        // hardware. A single failed IOKit open is not evidence that a Mac has no
        // sensors, and saying "No sensors on this Mac" after one was a false
        // hardware claim that outlived its cause.
        if readings.connectionFailed {
            return "Could not reach the SMC — relaunch Lidless to try again"
        }
        // Only once a sample has actually completed: before that, empty
        // readings mean "not yet", and saying "no sensors" would be a wrong
        // claim that corrects itself a moment later.
        if readings.sampled && !readings.hasAny { return "No sensors on this Mac" }
        return nil
    }
}

// MARK: - One sample

/// What one pass over the SMC produced. Every reading is a plain `Optional`,
/// not the value+`Readable` flag pair used across `SystemState`
/// (`SystemProbe.swift:435-438`). The flag exists there because `false` is a
/// plausible-looking fallback that a failed probe is indistinguishable from;
/// here there is no fallback at all — nil *is* the representation, and a nil
/// chip is simply not drawn.
struct SensorReadings: Sendable, Equatable {
    var systemWatts: Double?
    var cpuCelsius: Double?
    var gpuCelsius: Double?
    var batteryCelsius: Double?
    var fanRPM: Double?

    /// True once a sample has completed, whatever it found. This separates "no
    /// reading yet" from "this Mac exposes none of these keys", which look
    /// identical in the values alone and want opposite things said about them.
    var sampled = false

    /// True when the SMC connection itself could not be opened, as opposed to
    /// opening fine and exposing nothing. The two look identical in the values
    /// and want opposite things said about them: one is this Mac's hardware, the
    /// other is a failure on this run that a relaunch may clear.
    var connectionFailed = false

    /// True once the sampler has given up permanently — see
    /// `docs/SMC_SENSORS.md`. Values may still be present and are then the last
    /// ones known, not live.
    var abandoned = false

    var hasAny: Bool {
        systemWatts != nil || cpuCelsius != nil || gpuCelsius != nil
            || batteryCelsius != nil || fanRPM != nil
    }
}

// MARK: - When to give up on a sample

/// What one tick of the sampler should do. Pure and unit-tested, because the
/// controller that acts on it is not: this decision is one-way — `.abandon`
/// kills the strip for the life of the process — and it got the answer wrong on
/// a perfectly healthy Mac for months (see `sampleVerdict`).
enum SensorSampleVerdict: Sendable, Equatable {
    /// Nothing outstanding: take a sample.
    case start
    /// Outstanding and still plausible. Let it finish.
    case wait
    /// Outstanding, but the kernel is not what is late: either the sampling task
    /// has not been given a thread yet, or it has already answered and only the
    /// hop back to the main actor is outstanding. Restart the clock, so neither
    /// a busy main actor nor a starved background task can be mistaken for a
    /// wedged SMC call.
    case resetClock
    /// Outstanding, unanswered, and past the deadline. Stuck in the kernel.
    case abandon
}

enum SensorSampling {
    /// `elapsed` is measured from the moment the sample was dispatched, which is
    /// NOT the same as how long the SMC has been working. Two things routinely
    /// sit between the two, and only the sampling thread can report either:
    ///
    /// - `callStarted` — the detached task is `.background` QoS, and this app
    ///   blocks the main thread on purpose (`executePrivileged` runs `pmset`
    ///   synchronously under `Shell.defaultTimeout`, twice the abandon
    ///   deadline). A task that has not been given a thread yet has asked the
    ///   kernel for nothing and cannot be wedged in it.
    /// - `callReturned` — the answer is in and only the hop back to the main
    ///   actor is queued behind whatever is holding that actor.
    ///
    /// Measured on the machine this was first seen on, an SMC read takes about
    /// 80 ms (0.7 s on the very first call, which enumerates the keys). Nothing
    /// near ten seconds is a real reading, so a deadline hit while either flag
    /// is false says something about this app's own scheduling, not about the
    /// SMC.
    static func sampleVerdict(
        inFlight: Bool,
        elapsed: TimeInterval,
        callStarted: Bool,
        callReturned: Bool,
        abandonAfter: TimeInterval
    ) -> SensorSampleVerdict {
        guard inFlight else { return .start }
        if callReturned || !callStarted { return .resetClock }
        return elapsed > abandonAfter ? .abandon : .wait
    }
}

// MARK: - The SMC itself (impure, not unit-tested)

/// The IOKit half. Untested by design, exactly as `screenLock()` is untested
/// while `screenLock(in:)` is: there is no way to fake an `AppleSMC` driver,
/// so everything decidable was pushed into `SMCDecode` above and this half is
/// kept as thin as it can be.
///
/// **Never call this from `SystemProbe.read` or anything `refresh()` touches.**
/// `IOConnectCallStructMethod` has no timeout and cannot be cancelled; the
/// caller's only defence is to stop asking. See the file header and §1 of the
/// plan.
enum SMCConnection {
    // MARK: The 80-byte trap

    private struct Vers {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct PLimit {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpu: UInt32 = 0
        var gpu: UInt32 = 0
        var mem: UInt32 = 0
    }

    /// `p1`/`p2`/`p3` are not fields the driver defines — they are the tail
    /// padding C adds after `attr`, which Swift does not add on its own. See
    /// `expectedStride` for what happens without them.
    private struct KInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var attr: UInt8 = 0
        var p1: UInt8 = 0
        var p2: UInt8 = 0
        var p3: UInt8 = 0
    }

    private struct KeyData {
        var key: UInt32 = 0
        var vers = Vers()
        var pLimit = PLimit()
        var keyInfo = KInfo()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        /// Padding, same story as `KInfo.p1`-`p3`.
        var pad: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
            = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
               0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    /// The struct the driver expects, in bytes.
    ///
    /// This is checked before the connection is opened and the whole sampler
    /// gives up if it does not hold. Without the explicit padding above, a
    /// direct Swift translation of the C definition comes out at **76** bytes,
    /// every call returns `kIOReturnBadArgument` (`0xE00002C2`), and — the part
    /// that costs an afternoon — a failed call is indistinguishable from an
    /// absent key, so the machine looks like it has no sensors at all. The
    /// first pass of this investigation concluded exactly that, wrongly
    /// (`docs/SMC_SENSORS.md` §1).
    private static let expectedStride = 80

    /// Selector 2 is the SMC's keyed interface (`KERNEL_INDEX_SMC`).
    private static let smcSelector: UInt32 = 2

    private static let cmdReadBytes: UInt8 = 5
    private static let cmdKeyByIndex: UInt8 = 8
    private static let cmdKeyInfo: UInt8 = 9

    /// The largest payload the struct can carry. A key claiming more than this
    /// is refused rather than truncated.
    private static let maxPayload = 32

    // MARK: Cached connection

    /// Serialises everything below. The sampler only ever has one call in
    /// flight (see `Lidless.sampleSensors`), so this is never contended in
    /// practice — it is here so a future second caller cannot corrupt the
    /// cached state silently.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var connection: io_connect_t = 0
    /// nil until the first sample; the ~60 keys that group to something, so the
    /// 2130-key enumeration happens once per process rather than every tick.
    nonisolated(unsafe) private static var cachedKeys: [(key: UInt32, group: SMCGroup)]?
    /// Set on a stride mismatch or a failed open. One-way: this process will
    /// not try the SMC again.
    nonisolated(unsafe) private static var unavailable = false

    /// Takes one sample. Blocking, uncancellable, and safe to call only from a
    /// detached background task whose result the caller is willing to discard.
    static func read() -> SensorReadings {
        lock.lock()
        defer { lock.unlock() }

        var readings = SensorReadings()
        readings.sampled = true
        // Every later sample after a failed open reports the same cause, rather
        // than an empty strip that reads as "this Mac has no sensors".
        guard !unavailable else {
            readings.connectionFailed = true
            return readings
        }
        guard let keys = ensureConnected() else {
            unavailable = true
            readings.connectionFailed = true
            return readings
        }

        var cpu: [(key: String, value: SMCKeyValue)] = []
        var gpu: [(key: String, value: SMCKeyValue)] = []
        var battery: [SMCKeyValue] = []
        for entry in keys {
            guard let value = readKey(entry.key) else { continue }
            switch entry.group {
            case .cpuTemp: cpu.append((fourCCString(entry.key), value))
            case .gpuTemp: gpu.append((fourCCString(entry.key), value))
            case .batteryTemp: battery.append(value)
            case .systemPower: readings.systemWatts = SMCDecode.watts(value)
            // The maximum across actual-speed keys answers for the fastest
            // currently spinning fan on machines with more than one. Min/max
            // capability and target keys never enter this group.
            case .fanSpeed:
                if let rpm = SMCDecode.rpm(value) {
                    readings.fanRPM = max(readings.fanRPM ?? rpm, rpm)
                }
            }
        }
        readings.cpuCelsius = SMCDecode.cpuAverage(cpu, chipName: chipName())
        readings.gpuCelsius = SMCDecode.gpuTemperature(gpu, chipName: chipName())
        readings.batteryCelsius = SMCDecode.maxCelsius(battery)
        return readings
    }

    // MARK: Connection and key cache

    /// The marketing chip name is stable enough to select an undocumented SMC
    /// key generation (for example, "Apple M4 Max"). No subprocess is used;
    /// this is the same in-process sysctl value shown by System Information.
    private static func chipName() -> String? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0,
              size > 1 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else {
            return nil
        }
        return String(cString: bytes)
    }

    /// Returns the cached key list, opening the connection and enumerating on
    /// the first call. nil means the SMC is not usable on this Mac.
    private static func ensureConnected() -> [(key: UInt32, group: SMCGroup)]? {
        if let cached = cachedKeys { return cached }
        guard MemoryLayout<KeyData>.stride == expectedStride else { return nil }

        if connection == 0 {
            let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                      IOServiceMatching("AppleSMC"))
            guard service != 0 else { return nil }
            defer { IOObjectRelease(service) }
            var opened: io_connect_t = 0
            guard IOServiceOpen(service, mach_task_self_, 0, &opened) == kIOReturnSuccess,
                  opened != 0 else { return nil }
            connection = opened
        }

        // `#KEY` is itself a key, and its value is the number of keys.
        guard let countValue = readKey(fourCC("#KEY")), countValue.bytes.count == 4 else {
            return nil
        }
        // Big-endian here, unlike `flt `: this is a `ui32` count, and the
        // inconsistency is the one `docs/SMC_SENSORS.md` §5 warns about. It is
        // safe to rely on only because a wrong read produces an absurd count,
        // which the bound below rejects outright.
        let count = countValue.bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, count < 100_000 else { return nil }

        var found: [(key: UInt32, group: SMCGroup)] = []
        for index in 0..<count {
            var request = KeyData()
            var response = KeyData()
            request.data8 = cmdKeyByIndex
            request.data32 = index
            guard call(&request, &response) == kIOReturnSuccess else { continue }
            guard let group = SMCDecode.group(fourCCString(response.key)) else { continue }
            found.append((key: response.key, group: group))
        }
        cachedKeys = found
        return found
    }

    /// Reads one key's type and bytes, or nil if the key is absent, oversized,
    /// or the call failed. These three are not distinguished on purpose: a
    /// failed call and an absent key are indistinguishable at this interface,
    /// which is precisely the trap documented at `expectedStride`.
    private static func readKey(_ key: UInt32) -> SMCKeyValue? {
        var infoRequest = KeyData()
        var infoResponse = KeyData()
        infoRequest.key = key
        infoRequest.data8 = cmdKeyInfo
        guard call(&infoRequest, &infoResponse) == kIOReturnSuccess else { return nil }

        let info = infoResponse.keyInfo
        let size = Int(info.dataSize)
        guard size > 0, size <= maxPayload else { return nil }

        var request = KeyData()
        var response = KeyData()
        request.key = key
        request.data8 = cmdReadBytes
        request.keyInfo = info
        guard call(&request, &response) == kIOReturnSuccess else { return nil }

        let bytes = withUnsafeBytes(of: response.bytes) { Array($0.prefix(size)) }
        return SMCKeyValue(type: fourCCString(info.dataType), size: size, bytes: bytes)
    }

    private static func call(_ input: inout KeyData, _ output: inout KeyData) -> kern_return_t {
        var outputSize = MemoryLayout<KeyData>.stride
        return IOConnectCallStructMethod(connection, smcSelector,
                                         &input, MemoryLayout<KeyData>.stride,
                                         &output, &outputSize)
    }

    /// SMC keys and types are four ASCII characters packed big-endian into a
    /// `UInt32` — `"flt "`, `"PSTR"`, and so on.
    private static func fourCC(_ text: String) -> UInt32 {
        var packed: UInt32 = 0
        for byte in text.utf8.prefix(4) { packed = (packed << 8) | UInt32(byte) }
        return packed
    }

    private static func fourCCString(_ packed: UInt32) -> String {
        var bytes: [UInt8] = []
        for shift in stride(from: 24, through: 0, by: -8) {
            bytes.append(UInt8((packed >> UInt32(shift)) & 0xFF))
        }
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}
