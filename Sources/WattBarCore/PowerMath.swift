import Foundation

/// One row of the panel: a component, a power source, or an app.
public struct PowerReading: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let watts: Double
    public var detail: String?

    public init(id: String, label: String, watts: Double, detail: String? = nil) {
        self.id = id
        self.label = label
        self.watts = watts
        self.detail = detail
    }
}

/// A raw Energy Model channel: the counter name as IOReport reports it, and
/// its average power over the sampling interval.
public struct ComponentSample: Sendable {
    public let name: String
    public let watts: Double

    public init(name: String, watts: Double) {
        self.name = name
        self.watts = watts
    }
}

/// A share of the attributable budget assigned to one app.
public struct AppPower: Sendable {
    public let name: String
    public let watts: Double

    public init(name: String, watts: Double) {
        self.name = name
        self.watts = watts
    }
}

/// One point of power history.
public struct PowerSample: Sendable {
    public let time: ContinuousClock.Instant
    public let watts: Double

    public init(time: ContinuousClock.Instant, watts: Double) {
        self.time = time
        self.watts = watts
    }
}

public struct HistoryStats: Sendable {
    public let average: Double
    public let peak: Double
}

/// Whether the SMC total and the IOReport component counters agree closely
/// enough for the residual between them to mean anything.
public enum RestVerdict: Equatable, Sendable {
    /// The components fit under the system total; `rest` is the residual,
    /// clamped at zero.
    case coherent(rest: Double)
    /// The components sum above the system total by more than the tolerance,
    /// so the two sources are describing different moments in time.
    case incoherent
}

/// Pure power arithmetic: no hardware access, no state. Everything here is a
/// function of its arguments, which is what makes it testable.
public enum PowerMath {
    public static let componentOrder = [
        "CPU", "GPU", "Neural Engine", "Memory", "Display", "Media Engine", "Fabric & I/O",
    ]

    /// Weight cap per history sample, so the gap across a system sleep doesn't
    /// let one stale reading dominate the average.
    public static let maxSampleWeight = 30.0

    /// How far the component sum may exceed the system total before the two
    /// readings are treated as incoherent rather than as a negative residual.
    public static let coherenceTolerance = 0.25

    /// Buckets Energy Model channels into display components using
    /// mactop-style matching: substring/prefix rules that sum multiple
    /// channels, since chips split them differently across generations
    /// (single "CPU Energy", M1-style "ECPU"/"PCPU Energy", Ultra-style
    /// per-die "ANE0"/"DRAM0"/"DRAM1"). GPU SRAM is folded into GPU. Bare
    /// "CPU"/"GPU" channels are fallbacks when no primary channel matched.
    ///
    /// Per-cluster CPU channels (PCPU/MCPU/MCPM and their SRAM variants) are
    /// deliberately unmatched: "CPU Energy" already covers them, and matching
    /// both would double-count.
    public static func bucketComponents(_ samples: [ComponentSample]) -> [String: Double] {
        var watts: [String: Double] = [:]
        var bareCPU: Double?
        var bareGPU: Double?
        for sample in samples {
            let name = sample.name
            if name.contains("CPU Energy") {
                watts["CPU", default: 0] += sample.watts
            } else if name.hasPrefix("GPU SRAM") {
                watts["GPU", default: 0] += sample.watts
            } else if name == "GPU Energy" {
                watts["GPU", default: 0] += sample.watts
            } else if name.hasPrefix("ANE") {
                watts["Neural Engine", default: 0] += sample.watts
            } else if name.hasPrefix("DRAM") || name.hasPrefix("DCS") || name.hasPrefix("AMCC") {
                watts["Memory", default: 0] += sample.watts
            } else if name.hasPrefix("DISP") {
                watts["Display", default: 0] += sample.watts
            } else if name.hasPrefix("ISP") || name.hasPrefix("AVE") || name.hasPrefix("AVD")
                || name.hasPrefix("MSR") {
                watts["Media Engine", default: 0] += sample.watts
            } else if name.hasPrefix("FAB") || name.hasPrefix("AFR")
                || name.hasPrefix("PCIe Port") || name.hasPrefix("apciec") {
                watts["Fabric & I/O", default: 0] += sample.watts
            } else if name == "CPU" {
                bareCPU = sample.watts
            } else if name == "GPU" {
                bareGPU = sample.watts
            }
        }
        if watts["CPU"] == nil { watts["CPU"] = bareCPU }
        if watts["GPU"] == nil { watts["GPU"] = bareGPU }
        return watts
    }

    /// The SMC total is instantaneous; the component counters are averages
    /// over the interval since the previous sample. Comparing them directly
    /// lets the components sum above the total. The endpoint average of two
    /// consecutive instantaneous totals is the natural estimate of the mean
    /// over the interval between them.
    public static func intervalAverage(current: Double?, previous: Double?) -> Double? {
        intervalAverage(readings: current.map { [$0] } ?? [], previous: previous)
    }

    /// The same estimate when the total was also read at evenly spaced points
    /// inside the interval: the trapezoid mean from the previous interval's
    /// last reading through `readings`, which is the endpoint average when
    /// there is just one.
    public static func intervalAverage(readings: [Double], previous: Double?) -> Double? {
        guard let last = readings.last else { return nil }
        let mean = readings.reduce(0, +) / Double(readings.count)
        guard let previous else { return mean }
        return mean + (previous - last) / (2 * Double(readings.count))
    }

    /// Plain mean of the readings taken over an interval; nil when there were
    /// none.
    public static func mean(_ readings: [Double]) -> Double? {
        readings.isEmpty ? nil : readings.reduce(0, +) / Double(readings.count)
    }

    /// Power not covered by the SoC energy counters: display backlight, SSD
    /// NAND, radios, speakers, fans, and power-conversion losses. Only
    /// meaningful when the two sources agree; past the tolerance they are
    /// describing different moments and the residual is noise.
    public static func reconcileRest(
        componentSum: Double,
        intervalSystemWatts: Double,
        tolerance: Double = coherenceTolerance
    ) -> RestVerdict {
        let rest = intervalSystemWatts - componentSum
        guard rest >= -tolerance else { return .incoherent }
        return .coherent(rest: max(0, rest))
    }

    /// Fixed part of Rest of System: a low percentile of the residuals seen
    /// over the last hour. A percentile rather than the minimum, so a single
    /// noisy dip (the SMC total and the energy counters are sampled at
    /// slightly different moments) doesn't drag the floor down.
    public static func restFloor(_ residuals: [Double]) -> Double? {
        guard !residuals.isEmpty else { return nil }
        let sorted = residuals.sorted()
        return sorted[Int(Double(sorted.count - 1) * 0.1)]
    }

    /// The slice of system power plausibly caused by app activity, to be
    /// split by CPU-time share: CPU package, memory, and fabric power all
    /// track the work apps do, as does the part of the Rest of System
    /// residual above its idle floor (dominated by power-conversion losses,
    /// which scale with SoC draw, plus SSD activity). GPU, Neural Engine,
    /// and Media Engine are excluded: CPU time is a poor proxy for them,
    /// so their power stays in the remainder.
    ///
    /// Capped at the interval-aligned system total, so per-app attribution
    /// can never exceed the headline.
    public static func attributableBudget(
        components: [PowerReading],
        restFloor: Double?,
        intervalSystemWatts: Double?
    ) -> Double? {
        var budget: Double?
        for reading in components {
            switch reading.id {
            case "CPU", "Memory", "Fabric & I/O":
                budget = (budget ?? 0) + reading.watts
            case "_rest":
                if let restFloor {
                    budget = (budget ?? 0) + max(0, reading.watts - restFloor)
                }
            default:
                break
            }
        }
        guard let budget else { return nil }
        return min(budget, intervalSystemWatts ?? budget)
    }

    /// Turns per-app shares into panel rows, with a remainder row so the
    /// section adds up to the system total: the fixed Rest of System floor,
    /// GPU/ANE/media/display power, unreadable privileged processes, and apps
    /// below the display threshold.
    public static func appReadings(apps: [AppPower], intervalSystemWatts: Double?) -> [PowerReading] {
        var readings = apps.map { PowerReading(id: $0.name, label: $0.name, watts: $0.watts) }
        if let intervalSystemWatts {
            let attributed = apps.reduce(0) { $0 + $1.watts }
            let other = max(0, intervalSystemWatts - attributed)
            if other >= 0.01 {
                readings.append(PowerReading(id: "_other", label: "System & Other", watts: other))
            }
        }
        return readings
    }

    /// Time-weighted average and peak over the history window. Samples are
    /// weighted by the gap to the next one so mixed update intervals average
    /// correctly; the last sample is weighted by the current update interval
    /// since its own interval has not elapsed yet.
    public static func historyStats(
        _ samples: [PowerSample],
        trailingWeight: Double,
        maxSampleWeight: Double = maxSampleWeight
    ) -> HistoryStats? {
        guard let last = samples.last else { return nil }

        var weightedSum = 0.0
        var totalWeight = 0.0
        var peak = 0.0
        for (index, sample) in samples.enumerated() {
            peak = max(peak, sample.watts)
            let weight = index + 1 < samples.count
                ? min(sample.time.duration(to: samples[index + 1].time).timeInterval, maxSampleWeight)
                : min(trailingWeight, maxSampleWeight)
            weightedSum += sample.watts * weight
            totalWeight += weight
        }
        return HistoryStats(
            average: totalWeight > 0 ? weightedSum / totalWeight : last.watts,
            peak: peak
        )
    }

    /// Drops samples older than `window`, in place.
    public static func trim(_ samples: inout [PowerSample], before cutoff: ContinuousClock.Instant) {
        // endIndex, not nil-means-keep: when every sample predates the cutoff
        // there is no first valid one, and the whole history goes.
        let firstValid = samples.firstIndex { $0.time >= cutoff } ?? samples.endIndex
        samples.removeSubrange(..<firstValid)
    }
}
