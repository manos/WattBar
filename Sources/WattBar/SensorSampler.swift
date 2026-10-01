import Foundation
import WattBarCore

/// One complete reading of the machine, as a value that can cross actor
/// boundaries. `systemWatts` stays instantaneous because the headline is a
/// "right now" number; everything derived from the component counters uses
/// `intervalSystemWatts` instead, since those counters are interval averages.
struct PowerSnapshot: Sendable {
    let systemWatts: Double?
    let intervalSystemWatts: Double?
    let isAvailable: Bool
    /// Power flowing into the battery; zero unless charging. Not part of
    /// `systemWatts`, which is what the machine itself consumes.
    let chargeWatts: Double
    let sources: [PowerReading]
    /// nil when the energy counters had no interval to average over yet, in
    /// which case the caller keeps its previous breakdown.
    let components: ComponentBreakdown?
    /// nil when apps were not sampled, or when there was no interval to
    /// compare against yet.
    let apps: [AppPower]?
}

/// Owns every hardware handle and does all the blocking work: SMC ioctls,
/// IOKit battery reads, IOReport sampling, and the all-process sweep. Callers
/// get back a value snapshot, so nothing that touches hardware ever runs on
/// the main actor.
actor SensorSampler {
    /// SMC power channels. PSTR is the headline number: total system power,
    /// matching mactop's "Total System Power".
    private static let sourceChannels: [(key: String, label: String)] = [
        ("PDTR", "Power Adapter"),
        ("PPBR", "Battery"),
    ]

    private static let historyWindow: Duration = .seconds(3600)

    /// Every hardware handle, constructed together on first use. Opening the
    /// SMC and IOKit services and scanning every SMC key for temperature
    /// sensors costs the better part of a second, and an actor's initializer
    /// runs on whichever thread created it, which for PowerMonitor is the main
    /// one. Building them here instead keeps that cost on the actor's executor.
    private struct Resources {
        let smc: SMC?
        let battery: BatteryInfo?
        let energy: EnergyModel?
        let temperatures: TemperatureSensors?
        let appSampler = AppPowerSampler()

        init() {
            let smc = SMC()
            self.smc = smc
            battery = BatteryInfo()
            energy = EnergyModel()
            temperatures = smc.map(TemperatureSensors.init)
        }
    }

    private var resources: Resources?

    /// Previous instantaneous system total, for interval alignment.
    private var previousSystemWatts: Double?
    /// Last breakdown produced, so the app budget survives a refresh where
    /// the energy counters had nothing new to report.
    private var lastComponents: [PowerReading] = []
    /// The coherence state machine: decides whether this interval's rows can
    /// be published or the last coherent set should be republished.
    private var reconciler = ComponentReconciler()
    /// Rest of System residuals over the last hour, used to estimate the
    /// fixed part of that residual (backlight, SSD, radios) as a floor.
    private var restHistory: [PowerSample] = []
    /// Whether the previous snapshot swept processes. When app sampling
    /// resumes after a gap it rebaselines, rather than averaging its first
    /// estimate over however long it was paused.
    private var sampledAppsLastSnapshot = false

    init() {}

    /// Cheap after the first call: the handles are opened once and kept.
    private func loadResources() -> Resources {
        if let resources { return resources }
        let created = Resources()
        resources = created
        return created
    }

    func snapshot(includeApps: Bool, topCount: Int) -> PowerSnapshot {
        let resources = loadResources()
        let systemWatts = resources.smc?.readValue(key: "PSTR")
        let intervalSystemWatts = PowerMath.intervalAverage(
            current: systemWatts, previous: previousSystemWatts
        )
        previousSystemWatts = systemWatts

        var components: ComponentBreakdown?
        if let samples = resources.energy?.sample() {
            let breakdown = componentReadings(
                from: samples,
                intervalSystemWatts: intervalSystemWatts,
                temperatures: resources.temperatures
            )
            components = breakdown
            if let breakdown {
                lastComponents = breakdown.readings
            }
        }

        var apps: [AppPower]?
        if includeApps {
            if !sampledAppsLastSnapshot {
                resources.appSampler.reset()
            }
            let budget = PowerMath.attributableBudget(
                components: lastComponents,
                restFloor: PowerMath.restFloor(restHistory.map(\.watts)),
                intervalSystemWatts: intervalSystemWatts
            )
            apps = resources.appSampler.sample(budgetWatts: budget, topCount: topCount)
        }
        sampledAppsLastSnapshot = includeApps

        let battery = resources.battery?.read()
        return PowerSnapshot(
            systemWatts: systemWatts,
            intervalSystemWatts: intervalSystemWatts,
            isAvailable: systemWatts != nil,
            chargeWatts: battery?.chargeWatts ?? 0,
            sources: readSources(resources, battery: battery),
            components: components,
            apps: apps
        )
    }

    /// Discards app-sampling history and takes a fresh baseline sweep, so the
    /// next snapshot has an interval to compare against rather than an average
    /// over however long sampling was paused.
    func resetAppBaseline(topCount: Int) {
        let resources = loadResources()
        resources.appSampler.reset()
        _ = resources.appSampler.sample(budgetWatts: nil, topCount: topCount)
        sampledAppsLastSnapshot = true
    }

    private func readSources(
        _ resources: Resources, battery: BatteryInfo.State?
    ) -> [PowerReading] {
        var sources = Self.sourceChannels.compactMap { channel in
            resources.smc?.readValue(key: channel.key).map {
                PowerReading(id: channel.key, label: channel.label, watts: $0)
            }
        }

        // While charging, PPBR (power drawn from the battery) reads near
        // zero, leaving the adapter's extra output unexplained. Show the
        // charge inflow instead, flagged so the panel can annotate it.
        if let state = battery, state.isCharging,
           let index = sources.firstIndex(where: { $0.id == "PPBR" }) {
            sources[index] = PowerReading(
                id: "PPBR",
                label: "Battery",
                watts: state.chargeWatts,
                detail: "charging"
            )
        }
        return sources
    }

    private func componentReadings(
        from samples: [ComponentSample],
        intervalSystemWatts: Double?,
        temperatures: TemperatureSensors?
    ) -> ComponentBreakdown? {
        let watts = PowerMath.bucketComponents(samples)
        let cpuTemp = temperatures?.cpuCelsius
        let gpuTemp = temperatures?.gpuCelsius
        let readings = PowerMath.componentOrder.compactMap { label in
            watts[label].map { value in
                let temp = switch label {
                case "CPU": cpuTemp
                case "GPU": gpuTemp
                default: Double?.none
                }
                return PowerReading(
                    id: label,
                    label: label,
                    watts: value,
                    detail: temp.map { String(format: "%.0f°C", $0) }
                )
            }
        }

        let outcome = reconciler.reconcile(
            readings: readings, intervalSystemWatts: intervalSystemWatts
        )
        if let rest = outcome.coherentRest {
            recordRest(rest)
        }
        return outcome.breakdown
    }

    private func recordRest(_ watts: Double) {
        let now = ContinuousClock.now
        restHistory.append(PowerSample(time: now, watts: watts))
        PowerMath.trim(&restHistory, before: now - Self.historyWindow)
    }
}
