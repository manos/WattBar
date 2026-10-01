import Foundation
import WattBarCore

@main
@MainActor
enum Main {
    static func main() async {
        if CommandLine.arguments.contains("--probe") {
            await probe()
            return
        }
        if CommandLine.arguments.contains("--dump") {
            dump()
            return
        }
        if CommandLine.arguments.contains("--login-status") {
            loginStatus()
            return
        }
        if CommandLine.arguments.contains("--apps") {
            await apps()
            return
        }
        if CommandLine.arguments.contains("--components") {
            await components()
            return
        }
        LaunchAtLogin.registerIfNeeded()
        WattBarApp.main()
    }

    /// Prints one reading of every power channel and exits. Lets the SMC
    /// layer be verified from the command line: `WattBar --probe`
    private static func probe() async {
        guard let smc = SMC() else {
            print("error: could not open AppleSMC connection")
            exit(1)
        }
        for key in ["PSTR", "PDTR", "PPBR"] {
            if let value = smc.readValue(key: key) {
                print("\(key): \(String(format: "%.2f", value)) W")
            } else {
                print("\(key): unavailable")
            }
        }

        if let state = BatteryInfo()?.read() {
            let status = state.isCharging
                ? String(format: "charging at %.2f W", state.chargeWatts)
                : "not charging"
            print("battery: \(status)")
        } else {
            print("battery: unavailable")
        }

        let temperatures = TemperatureSensors(smc: smc)
        let format = { (value: Double?) in
            value.map { String(format: "%.1f°C", $0) } ?? "unavailable"
        }
        print("CPU temp: \(format(temperatures.cpuCelsius))")
        print("GPU temp: \(format(temperatures.gpuCelsius))")
        print("thermal state:", ProcessInfo.processInfo.thermalState.rawValue)

        guard let energy = EnergyModel() else {
            print("Energy Model: unavailable")
            return
        }
        _ = energy.sample()
        try? await Task.sleep(for: .seconds(1))
        for component in energy.sample() ?? [] {
            print("\(component.name): \(String(format: "%.2f", component.watts)) W")
        }
    }

    /// Prints login item state as seen from the app bundle:
    /// `WattBar.app/Contents/MacOS/WattBar --login-status`
    private static func loginStatus() {
        print("bundle:", Bundle.main.bundlePath)
        print("status:", LaunchAtLogin.isEnabled ? "enabled" : "not enabled")
        print("autoRegistered:", UserDefaults.standard.bool(forKey: "didAutoRegisterLoginItem"))
    }

    private static let cliTopCount = 6
    private static let cliWindowSeconds = 2

    /// Reads the power channels once a second across the window, as the app
    /// does between refreshes; the closing snapshot takes the last reading.
    private static func sampleWindow(_ sampler: SensorSampler) async {
        for second in 1...cliWindowSeconds {
            try? await Task.sleep(for: .seconds(1))
            if second < cliWindowSeconds {
                await sampler.sampleChannels()
            }
        }
    }

    /// Prints estimated per-app power over a 2-second window, using the
    /// same budget-and-remainder path as the panel: `WattBar --apps`
    private static func apps() async {
        let sampler = SensorSampler()
        await sampler.resetAppBaseline(topCount: cliTopCount)
        _ = await sampler.snapshot(includeApps: true, topCount: cliTopCount)
        await sampleWindow(sampler)
        let snapshot = await sampler.snapshot(includeApps: true, topCount: cliTopCount)

        guard let apps = snapshot.apps else {
            print("error: no sample")
            exit(1)
        }
        printTotals(snapshot)
        for reading in PowerMath.appReadings(
            apps: apps, intervalSystemWatts: snapshot.intervalSystemWatts
        ) {
            print(String(format: "%6.2f W  %@", reading.watts, reading.label))
        }
    }

    /// Prints the bucketed component breakdown exactly as the panel computes
    /// it, including the Rest of System residual: `WattBar --components`
    private static func components() async {
        let sampler = SensorSampler()
        _ = await sampler.snapshot(includeApps: false, topCount: cliTopCount)
        await sampleWindow(sampler)
        let snapshot = await sampler.snapshot(includeApps: false, topCount: cliTopCount)

        guard snapshot.isAvailable else {
            print("error: power sensors unavailable")
            exit(1)
        }
        printTotals(snapshot)
        guard let breakdown = snapshot.components else { return }
        for reading in breakdown.readings {
            let detail = reading.detail.map { "  (\($0))" } ?? ""
            print(String(format: "%6.2f W  %@%@", reading.watts, reading.label, detail))
        }
        // Printed from the breakdown, not the snapshot: the rows above sum to
        // this number, even when the current interval was incoherent and these
        // are the last rows that added up.
        let marker = breakdown.isStale ? "  (stale)" : ""
        print(String(format: "Components total: %.2f W%@", breakdown.totalWatts, marker))
        // They sum to it exactly only when a Rest of System row was worth
        // emitting. When it wasn't, the leftover is still real, and at two
        // decimals it is large enough to read as an arithmetic error. Name it,
        // with the reason matched to its sign.
        let unattributed = breakdown.unattributedWatts
        if abs(unattributed) >= 0.005 {
            let reason = unattributed > 0
                ? "too small for a Rest of System row"
                : "rows overshot the total within tolerance"
            print(String(format: "  (%+.2f W residual, %@)", unattributed, reason))
        }
    }

    /// The rows below sum to the interval-aligned total, not the window mean:
    /// the energy counters they come from are averages over the window.
    private static func printTotals(_ snapshot: PowerSnapshot) {
        let format = { (value: Double?) in
            value.map { String(format: "%.2f W", $0) } ?? "unavailable"
        }
        print("System total (window mean):", format(snapshot.systemWatts))
        print("System total (interval):", format(snapshot.intervalSystemWatts))
        for source in snapshot.sources {
            let detail = source.detail.map { " (\($0))" } ?? ""
            print("\(source.label) (window mean):", format(source.watts) + detail)
        }
    }

    /// Prints every float-typed "P*" (power) sensor the SMC exposes:
    /// `WattBar --dump`
    private static func dump() {
        guard let smc = SMC() else {
            print("error: could not open AppleSMC connection")
            exit(1)
        }
        for key in smc.allKeys().sorted() where key.hasPrefix("P") {
            guard smc.typeOf(key: key) == "flt ",
                  let value = smc.readValue(key: key)
            else { continue }
            print("\(key): \(String(format: "%8.3f", value))")
        }
    }
}
