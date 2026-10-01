import Foundation
import Observation
import WattBarCore

@MainActor
@Observable
final class PowerMonitor {
    typealias Reading = PowerReading

    struct ChartPoint: Identifiable {
        let id: Int
        let minutesAgo: Double
        let watts: Double
    }

    private static let intervalKey = "updateInterval"
    private static let decimalsKey = "showsMenuBarDecimals"
    private static let chargingKey = "includesChargingPower"
    static let intervalOptions: [TimeInterval] = [1, 5, 10, 30, 60]

    /// At intervals this long, waiting a whole one after opening the panel for
    /// a first app estimate is noticeable, so apps are sampled in the
    /// background as well and the panel opens on the last interval's estimate.
    private static let backgroundAppInterval: TimeInterval = 5

    private(set) var systemWatts: Double?
    private(set) var chargeWatts: Double = 0
    private(set) var averageWatts: Double?
    private(set) var peakWatts: Double?
    private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    private(set) var chartPoints: [ChartPoint] = []
    /// The component rows and the interval total they add up to, as one value:
    /// a stale breakdown is shown against the total it reconciles to, never
    /// against a fresher one it does not.
    private(set) var componentBreakdown: ComponentBreakdown?
    private(set) var sources: [Reading] = []
    private(set) var appReadings: [Reading] = []
    private(set) var hasAppSample = false
    private(set) var isAvailable = true

    var updateInterval: TimeInterval {
        didSet {
            UserDefaults.standard.set(updateInterval, forKey: Self.intervalKey)
            // Restart the loop so a new interval applies now, rather than
            // after the old one's sleep runs out (up to a minute).
            guard updateInterval != oldValue, pollTask != nil else { return }
            stop()
            pollTask = pollLoop(refreshFirst: false)
        }
    }

    /// The menu bar is short on room, so whole watts by default.
    var showsMenuBarDecimals: Bool {
        didSet {
            UserDefaults.standard.set(showsMenuBarDecimals, forKey: Self.decimalsKey)
        }
    }

    /// Adds the battery's charge inflow to the headline and menu bar figure.
    /// History, average, and peak stay system power, so they don't jump
    /// whenever the charger kicks in.
    var includesChargingPower: Bool {
        didSet {
            UserDefaults.standard.set(includesChargingPower, forKey: Self.chargingKey)
        }
    }

    /// Per-app sampling sweeps every process. At short intervals it only runs
    /// while the panel is open, and opening the panel takes a fresh baseline.
    /// At longer ones it also runs in the background, so the panel opens on
    /// the last interval's estimate instead of waiting out a new one.
    var isPanelVisible = false {
        didSet {
            guard isPanelVisible, !oldValue else { return }
            rebuildChartPoints(now: .now)
            guard !appsSampledLastRefresh else { return }
            Task { await sampler.resetAppBaseline(topCount: Self.topAppCount) }
        }
    }

    /// Whether the last refresh swept processes, i.e. whether `appReadings`
    /// is being kept current. When it isn't, it has already been cleared.
    private var appsSampledLastRefresh = false

    private static let topAppCount = 6
    /// How often the power channels are read between refreshes.
    private static let channelSampleInterval: Duration = .seconds(1)
    private static let historyWindow: Duration = .seconds(3600)

    private var history: [PowerSample] = []

    private let sampler = SensorSampler()
    private var pollTask: Task<Void, Never>?

    init() {
        let stored = UserDefaults.standard.double(forKey: Self.intervalKey)
        updateInterval = Self.intervalOptions.contains(stored) ? stored : 1
        showsMenuBarDecimals = UserDefaults.standard.bool(forKey: Self.decimalsKey)
        includesChargingPower = UserDefaults.standard.bool(forKey: Self.chargingKey)
        start()
    }

    /// Whether the headline currently has charge power added to it, so the
    /// panel can say so: the rows below add up to system power alone.
    var headlineIncludesCharging: Bool {
        includesChargingPower && chargeWatts > 0
    }

    /// System power, plus the battery's charge inflow when asked for: what
    /// the machine is pulling in total, rather than what it consumes.
    private var headlineWatts: Double? {
        systemWatts.map { $0 + (includesChargingPower ? chargeWatts : 0) }
    }

    var statusText: String {
        guard let watts = headlineWatts else { return "-- W" }
        return String(format: "%.1f W", watts)
    }

    /// Compact form of `statusText`: no space before the unit, and decimals
    /// only when asked for.
    var menuBarText: String {
        guard let watts = headlineWatts else { return "--W" }
        return String(format: showsMenuBarDecimals ? "%.1fW" : "%.0fW", watts)
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = pollLoop(refreshFirst: true)
    }

    /// Ticks once a second: the power channels are read on every tick, and
    /// every `updateInterval` ticks a full refresh publishes their means. So
    /// a long interval shows the whole interval, not one instant of it.
    private func pollLoop(refreshFirst: Bool) -> Task<Void, Never> {
        Task { [weak self] in
            if refreshFirst { await self?.refresh() }
            var ticksSinceRefresh = 0
            while true {
                guard let self else { return }
                do {
                    try await Task.sleep(for: Self.channelSampleInterval)
                } catch {
                    return  // cancelled: no final refresh
                }
                guard !Task.isCancelled else { return }
                ticksSinceRefresh += 1
                let ticksPerRefresh = max(1, Int(self.updateInterval.rounded()))
                if ticksSinceRefresh >= ticksPerRefresh {
                    ticksSinceRefresh = 0
                    await self.refresh()
                } else {
                    await self.sampler.sampleChannels()
                }
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Awaiting the snapshot before sleeping again means a slow sample delays
    /// the next one rather than piling up behind it.
    func refresh() async {
        let includeApps = isPanelVisible || updateInterval >= Self.backgroundAppInterval
        let snapshot = await sampler.snapshot(
            includeApps: includeApps, topCount: Self.topAppCount
        )
        apply(snapshot)
        appsSampledLastRefresh = includeApps
        if !includeApps {
            // Nothing is keeping these current any more; don't let the panel
            // open on an estimate from whenever sampling last ran.
            appReadings = []
            hasAppSample = false
        }
    }

    private func apply(_ snapshot: PowerSnapshot) {
        systemWatts = snapshot.systemWatts
        chargeWatts = snapshot.chargeWatts
        isAvailable = snapshot.isAvailable
        sources = snapshot.sources
        thermalState = ProcessInfo.processInfo.thermalState

        if let breakdown = snapshot.components {
            componentBreakdown = breakdown
        }
        if let apps = snapshot.apps {
            hasAppSample = true
            appReadings = PowerMath.appReadings(
                apps: apps, intervalSystemWatts: snapshot.intervalSystemWatts
            )
        }
        if let watts = snapshot.systemWatts {
            recordHistory(watts)
        }
    }

    /// Appends a sample, drops entries older than the window, and updates the
    /// time-weighted average and peak.
    private func recordHistory(_ watts: Double) {
        let now = ContinuousClock.now
        history.append(PowerSample(time: now, watts: watts))
        PowerMath.trim(&history, before: now - Self.historyWindow)

        let stats = PowerMath.historyStats(history, trailingWeight: updateInterval)
        averageWatts = stats?.average
        peakWatts = stats?.peak

        if isPanelVisible {
            rebuildChartPoints(now: now)
        }
    }

    /// Downsamples history into 30-second buckets (keeping each bucket's
    /// maximum so spikes stay visible) for the panel sparkline.
    private func rebuildChartPoints(now: ContinuousClock.Instant) {
        let bucketSeconds = 30.0
        var maxByBucket: [Int: Double] = [:]
        for sample in history {
            let secondsAgo = sample.time.duration(to: now).timeInterval
            let bucket = Int(secondsAgo / bucketSeconds)
            maxByBucket[bucket] = max(maxByBucket[bucket] ?? 0, sample.watts)
        }
        chartPoints = maxByBucket
            .map { bucket, watts in
                ChartPoint(
                    id: bucket,
                    minutesAgo: -(Double(bucket) + 0.5) * bucketSeconds / 60,
                    watts: watts
                )
            }
            .sorted { $0.minutesAgo < $1.minutesAgo }
    }
}
