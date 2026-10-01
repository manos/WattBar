import Foundation
import Testing
@testable import WattBarCore

@Suite("Component bucketing")
struct BucketComponentsTests {
    @Test("cluster CPU channels sum into one CPU bucket")
    func cpuChannelsSum() {
        let watts = PowerMath.bucketComponents([
            ComponentSample(name: "CPU Energy", watts: 3),
            ComponentSample(name: "ECPU Energy", watts: 1),
            ComponentSample(name: "PCPU Energy", watts: 2),
        ])
        #expect(watts["CPU"] == 6)
    }

    @Test("GPU SRAM folds into GPU")
    func gpuSRAMFolds() {
        let watts = PowerMath.bucketComponents([
            ComponentSample(name: "GPU Energy", watts: 4),
            ComponentSample(name: "GPU SRAM Energy", watts: 0.5),
        ])
        #expect(watts["GPU"] == 4.5)
    }

    @Test("per-cluster CPU channels are ignored, since CPU Energy already covers them")
    func perClusterChannelsDoNotDoubleCount() {
        // These are the channels a real M-series chip reports alongside
        // "CPU Energy". Matching them too would double-count the package.
        let watts = PowerMath.bucketComponents([
            ComponentSample(name: "CPU Energy", watts: 10),
            ComponentSample(name: "PCPU", watts: 7),
            ComponentSample(name: "PCPU0_SRAM", watts: 0.3),
            ComponentSample(name: "MCPU0", watts: 0.5),
            ComponentSample(name: "MCPM0", watts: 0.1),
            ComponentSample(name: "MCPU0_0_SRAM", watts: 0.01),
        ])
        #expect(watts["CPU"] == 10)
    }

    @Test("a bare CPU channel is only a fallback")
    func bareCPUIsFallbackOnly() {
        let withPrimary = PowerMath.bucketComponents([
            ComponentSample(name: "CPU Energy", watts: 9),
            ComponentSample(name: "CPU", watts: 3),
        ])
        #expect(withPrimary["CPU"] == 9)

        let fallbackOnly = PowerMath.bucketComponents([
            ComponentSample(name: "CPU", watts: 3),
        ])
        #expect(fallbackOnly["CPU"] == 3)
    }

    @Test("a bare GPU channel is only a fallback")
    func bareGPUIsFallbackOnly() {
        let withPrimary = PowerMath.bucketComponents([
            ComponentSample(name: "GPU Energy", watts: 5),
            ComponentSample(name: "GPU", watts: 2),
        ])
        #expect(withPrimary["GPU"] == 5)

        let fallbackOnly = PowerMath.bucketComponents([ComponentSample(name: "GPU", watts: 2)])
        #expect(fallbackOnly["GPU"] == 2)
    }

    @Test("per-die channels sum into their bucket")
    func perDieChannelsSum() {
        let watts = PowerMath.bucketComponents([
            ComponentSample(name: "ANE0", watts: 0.2),
            ComponentSample(name: "ANE1", watts: 0.3),
            ComponentSample(name: "DRAM0", watts: 1),
            ComponentSample(name: "DRAM1", watts: 2),
            ComponentSample(name: "DCS", watts: 0.5),
            ComponentSample(name: "AMCC", watts: 0.5),
            ComponentSample(name: "DISP0", watts: 0.4),
            ComponentSample(name: "ISP", watts: 0.1),
            ComponentSample(name: "AVE", watts: 0.2),
            ComponentSample(name: "FAB", watts: 0.6),
            ComponentSample(name: "PCIe Port 0 Energy", watts: 0.1),
            ComponentSample(name: "apciec0 Energy", watts: 0.3),
        ])
        #expect(watts["Neural Engine"] == 0.5)
        #expect(watts["Memory"] == 4)
        #expect(watts["Display"] == 0.4)
        #expect(watts["Media Engine"] == 0.30000000000000004)
        #expect(watts["Fabric & I/O"] == 1)
    }

    @Test("an unrecognised channel lands in no bucket")
    func unknownChannelsAreDropped() {
        let watts = PowerMath.bucketComponents([ComponentSample(name: "SOMETHING", watts: 5)])
        #expect(watts.isEmpty)
    }
}

@Suite("Interval alignment and reconciliation")
struct ReconciliationTests {
    @Test("the interval total is the endpoint average of two instantaneous totals")
    func intervalAverage() {
        #expect(PowerMath.intervalAverage(current: 12, previous: 8) == 10)
    }

    @Test("with no previous total, the instantaneous one is the best estimate")
    func intervalAverageWithoutHistory() {
        #expect(PowerMath.intervalAverage(current: 12, previous: nil) == 12)
        #expect(PowerMath.intervalAverage(current: nil, previous: 8) == nil)
    }

    @Test("readings inside the interval give the trapezoid mean from the previous one")
    func intervalAverageOverReadings() {
        // 8 → 10 → 12 → 14, linear: the true mean over the interval is 11.
        #expect(PowerMath.intervalAverage(readings: [10, 12, 14], previous: 8) == 11)
        #expect(PowerMath.intervalAverage(readings: [12], previous: 8) == 10)
        #expect(PowerMath.intervalAverage(readings: [10, 14], previous: nil) == 12)
        #expect(PowerMath.intervalAverage(readings: [], previous: 8) == nil)
    }

    @Test("the mean of an interval's readings, nil when there were none")
    func meanOfReadings() {
        #expect(PowerMath.mean([9, 11, 16]) == 12)
        #expect(PowerMath.mean([]) == nil)
    }

    @Test("components below the total leave a positive residual")
    func componentsBelowTotal() {
        #expect(
            PowerMath.reconcileRest(componentSum: 6, intervalSystemWatts: 10)
                == .coherent(rest: 4)
        )
    }

    @Test("components equal to the total leave no residual")
    func componentsEqualTotal() {
        #expect(
            PowerMath.reconcileRest(componentSum: 10, intervalSystemWatts: 10)
                == .coherent(rest: 0)
        )
    }

    @Test("a small overshoot is sampling noise: coherent, but clamped to zero")
    func smallOvershootClampsToZero() {
        #expect(
            PowerMath.reconcileRest(componentSum: 10.2, intervalSystemWatts: 10)
                == .coherent(rest: 0)
        )
    }

    @Test("an overshoot past the tolerance means the two sources disagree")
    func largeOvershootIsIncoherent() {
        // The 2.74W overshoot the review observed at 0.5s intervals.
        #expect(
            PowerMath.reconcileRest(componentSum: 12.74, intervalSystemWatts: 10) == .incoherent
        )
        // Just past the 0.25W tolerance.
        #expect(
            PowerMath.reconcileRest(componentSum: 10.26, intervalSystemWatts: 10) == .incoherent
        )
    }

    @Test("the app budget never exceeds the system total")
    func budgetIsCappedAtTheSystemTotal() {
        // Components summing above the headline (which the caller only reaches
        // via a stale coherent set) must not hand the app sampler more watts
        // than the machine is drawing.
        let components = [
            PowerReading(id: "CPU", label: "CPU", watts: 8),
            PowerReading(id: "Memory", label: "Memory", watts: 3),
            PowerReading(id: "Fabric & I/O", label: "Fabric & I/O", watts: 2),
        ]
        let budget = PowerMath.attributableBudget(
            components: components, restFloor: nil, intervalSystemWatts: 10
        )
        #expect(budget == 10)
    }

    @Test("only activity-driven components are attributable")
    func onlyActivityDrivenComponentsCount() {
        let components = [
            PowerReading(id: "CPU", label: "CPU", watts: 4),
            PowerReading(id: "Memory", label: "Memory", watts: 1),
            PowerReading(id: "Fabric & I/O", label: "Fabric & I/O", watts: 0.5),
            // Excluded: CPU time is a poor proxy for these.
            PowerReading(id: "GPU", label: "GPU", watts: 6),
            PowerReading(id: "Neural Engine", label: "Neural Engine", watts: 2),
            PowerReading(id: "Media Engine", label: "Media Engine", watts: 1),
            PowerReading(id: "Display", label: "Display", watts: 1),
        ]
        let budget = PowerMath.attributableBudget(
            components: components, restFloor: nil, intervalSystemWatts: 100
        )
        #expect(budget == 5.5)
    }

    @Test("only the part of Rest of System above its idle floor is attributable")
    func restAboveFloorIsAttributable() {
        let components = [
            PowerReading(id: "CPU", label: "CPU", watts: 4),
            PowerReading(id: "_rest", label: "Rest of System", watts: 9),
        ]
        let budget = PowerMath.attributableBudget(
            components: components, restFloor: 6, intervalSystemWatts: 100
        )
        #expect(budget == 7)  // 4 CPU + (9 - 6) above the floor
    }

    @Test("with no floor established yet, Rest of System is not attributable")
    func restWithoutFloorIsNotAttributable() {
        let components = [
            PowerReading(id: "CPU", label: "CPU", watts: 4),
            PowerReading(id: "_rest", label: "Rest of System", watts: 9),
        ]
        let budget = PowerMath.attributableBudget(
            components: components, restFloor: nil, intervalSystemWatts: 100
        )
        #expect(budget == 4)
    }

    @Test("a residual below its floor does not subtract from the budget")
    func restBelowFloorDoesNotSubtract() {
        let components = [
            PowerReading(id: "CPU", label: "CPU", watts: 4),
            PowerReading(id: "_rest", label: "Rest of System", watts: 2),
        ]
        let budget = PowerMath.attributableBudget(
            components: components, restFloor: 6, intervalSystemWatts: 100
        )
        #expect(budget == 4)
    }

    @Test("no attributable components means no budget at all")
    func noAttributableComponentsMeansNoBudget() {
        let components = [PowerReading(id: "GPU", label: "GPU", watts: 6)]
        #expect(
            PowerMath.attributableBudget(
                components: components, restFloor: nil, intervalSystemWatts: 100
            ) == nil
        )
        #expect(
            PowerMath.attributableBudget(
                components: [], restFloor: nil, intervalSystemWatts: 100
            ) == nil
        )
    }
}

@Suite("Rest of System floor")
struct RestFloorTests {
    @Test("the floor is a low percentile, not the minimum")
    func floorIsAPercentile() {
        // A single noisy dip should not drag the floor down to itself.
        var residuals = Array(repeating: 8.0, count: 20)
        residuals[0] = 0.1
        let floor = try! #require(PowerMath.restFloor(residuals))
        #expect(floor == 8)
    }

    @Test("the floor sits at the tenth percentile of the residuals")
    func floorPicksTheTenthPercentile() {
        #expect(PowerMath.restFloor(Array(1...11).map(Double.init)) == 2)
    }

    @Test("no residuals means no floor")
    func emptyHistoryHasNoFloor() {
        #expect(PowerMath.restFloor([]) == nil)
    }

    @Test("a single residual is its own floor")
    func singleResidual() {
        #expect(PowerMath.restFloor([5]) == 5)
    }
}

@Suite("Apps section")
struct AppReadingsTests {
    @Test("the remainder row makes the section add up to the system total")
    func remainderBalancesTheSection() {
        let readings = PowerMath.appReadings(
            apps: [AppPower(name: "Xcode", watts: 6), AppPower(name: "Safari", watts: 2)],
            intervalSystemWatts: 20
        )
        #expect(readings.map(\.label) == ["Xcode", "Safari", "System & Other"])
        #expect(readings.reduce(0) { $0 + $1.watts } == 20)
    }

    @Test("the remainder never goes negative, even if attribution overshoots")
    func remainderIsClampedAtZero() {
        let readings = PowerMath.appReadings(
            apps: [AppPower(name: "Xcode", watts: 12)], intervalSystemWatts: 10
        )
        #expect(readings.count == 1)  // no negative "System & Other" row
        #expect(readings.allSatisfy { $0.watts >= 0 })
    }

    @Test("with no system total there is nothing to balance against")
    func noTotalMeansNoRemainderRow() {
        let readings = PowerMath.appReadings(
            apps: [AppPower(name: "Xcode", watts: 6)], intervalSystemWatts: nil
        )
        #expect(readings.map(\.id) == ["Xcode"])
    }
}

@Suite("History weighting")
struct HistoryStatsTests {
    private func samples(_ points: [(seconds: Double, watts: Double)]) -> [PowerSample] {
        let start = ContinuousClock.now
        return points.map { PowerSample(time: start.advanced(by: .seconds($0.seconds)), watts: $0.watts) }
    }

    @Test("a single sample averages to itself")
    func singleSample() {
        let stats = try! #require(
            PowerMath.historyStats(samples([(0, 12)]), trailingWeight: 1)
        )
        #expect(stats.average == 12)
        #expect(stats.peak == 12)
    }

    @Test("samples are weighted by the gap to the next one, so mixed intervals average correctly")
    func mixedIntervalsWeightCorrectly() {
        // 10W held for 4s, then 20W held for the 1s trailing interval.
        let stats = try! #require(
            PowerMath.historyStats(samples([(0, 10), (4, 20)]), trailingWeight: 1)
        )
        #expect(stats.average == 12)  // (10*4 + 20*1) / 5, not the naive 15
        #expect(stats.peak == 20)
    }

    @Test("a gap across sleep is capped, so one stale reading cannot dominate")
    func sleepGapIsCapped() {
        // An hour-long gap would otherwise give the first sample 3600s of
        // weight and pin the average to it.
        let stats = try! #require(
            PowerMath.historyStats(samples([(0, 10), (3600, 20)]), trailingWeight: 1)
        )
        // Capped at maxSampleWeight (30s): (10*30 + 20*1) / 31
        #expect(abs(stats.average - (10 * 30 + 20) / 31) < 1e-9)
        #expect(stats.average < 11)
    }

    @Test("the peak is the maximum, not the weighted value")
    func peakIsTheMaximum() {
        let stats = try! #require(
            PowerMath.historyStats(samples([(0, 5), (1, 40), (2, 5)]), trailingWeight: 1)
        )
        #expect(stats.peak == 40)
    }

    @Test("empty history has no stats")
    func emptyHistory() {
        #expect(PowerMath.historyStats([], trailingWeight: 1) == nil)
    }

    @Test("samples older than the cutoff are dropped")
    func trimmingDropsOldSamples() {
        let start = ContinuousClock.now
        var history = [
            PowerSample(time: start, watts: 1),
            PowerSample(time: start.advanced(by: .seconds(10)), watts: 2),
            PowerSample(time: start.advanced(by: .seconds(20)), watts: 3),
        ]
        PowerMath.trim(&history, before: start.advanced(by: .seconds(10)))
        // The sample exactly at the cutoff is kept.
        #expect(history.map(\.watts) == [2, 3])
    }

    @Test("a history that is entirely older than the cutoff is emptied")
    func trimmingDropsAnEntirelyExpiredHistory() {
        let start = ContinuousClock.now
        var history = [
            PowerSample(time: start, watts: 1),
            PowerSample(time: start.advanced(by: .seconds(10)), watts: 2),
        ]
        PowerMath.trim(&history, before: start.advanced(by: .seconds(3600)))
        #expect(history.isEmpty)
    }
}
