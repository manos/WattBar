import Charts
import SwiftUI
import WattBarCore

struct PowerPanelView: View {
    @Bindable var monitor: PowerMonitor
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchAtLoginError: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if monitor.isAvailable {
                VStack(alignment: .leading, spacing: 2) {
                    Text("System Power")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(monitor.statusText)
                        .font(.title)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    if let average = monitor.averageWatts, let peak = monitor.peakWatts {
                        Text(String(format: "Last hour: avg %.1f W · peak %.1f W", average, peak))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    thermalLine
                }

                if monitor.chartPoints.count > 1 {
                    sparkline
                }

                componentSection
                appSection
                readingSection("Power Source", readings: monitor.sources)
            } else {
                Label("Power sensors unavailable on this Mac", systemImage: "bolt.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Picker("Update Every", selection: $monitor.updateInterval) {
                ForEach(PowerMonitor.intervalOptions, id: \.self) { interval in
                    Text(String(format: "%.0fs", interval))
                        .tag(interval)
                }
            }
            .font(.callout)

            Toggle("Decimals in Menu Bar", isOn: $monitor.showsMenuBarDecimals)

            launchAtLoginToggle

            Button("Quit WattBar") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(14)
        .frame(minWidth: 250, idealWidth: 280, alignment: .leading)
        .onAppear {
            monitor.isPanelVisible = true
            // Resync: the login item can be changed in System Settings while
            // WattBar is running.
            launchAtLogin = LaunchAtLogin.isEnabled
        }
        .onDisappear { monitor.isPanelVisible = false }
    }

    private var launchAtLoginToggle: some View {
        Toggle("Launch at Login", isOn: $launchAtLogin)
            .onChange(of: launchAtLogin) { _, newValue in
                // Both the revert below and the onAppear resync write to
                // launchAtLogin, which re-fires this handler. Only act when
                // the new value disagrees with the system, so a write that
                // merely mirrors reality doesn't loop back into set().
                guard newValue != LaunchAtLogin.isEnabled else { return }
                do {
                    try LaunchAtLogin.set(enabled: newValue)
                } catch {
                    launchAtLoginError = error.localizedDescription
                    launchAtLogin = LaunchAtLogin.isEnabled
                }
            }
            .alert("Could not update login item", isPresented: .init(
                get: { launchAtLoginError != nil },
                set: { if !$0 { launchAtLoginError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text((launchAtLoginError ?? "") + """

                    If approval is required, allow WattBar in System Settings > \
                    General > Login Items.
                    """)
            }
    }

    private var sparkline: some View {
        Chart(monitor.chartPoints) { point in
            AreaMark(
                x: .value("Minutes Ago", point.minutesAgo),
                y: .value("Watts", point.watts)
            )
            .opacity(0.15)
            LineMark(
                x: .value("Minutes Ago", point.minutesAgo),
                y: .value("Watts", point.watts)
            )
            .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartXScale(domain: -60...0)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 40)
        .accessibilityLabel("System power over the last hour")
    }

    private var thermalLine: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(thermalColor)
                .frame(width: 7, height: 7)
            Text("Thermal pressure: \(thermalLabel)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var thermalLabel: String {
        switch monitor.thermalState {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }

    private var thermalColor: Color {
        switch monitor.thermalState {
        case .nominal: .green
        case .fair: .yellow
        case .serious: .orange
        case .critical: .red
        @unknown default: .gray
        }
    }

    private static let componentTotalHelp = """
    The rows below are averages over the update interval and add up to this \
    number, which is why they can differ a little from the instantaneous \
    figure at the top.

    A dimmed total means the sensors briefly disagreed, so WattBar is showing \
    the last set of rows that added up, alongside the total they add up to.
    """

    private static let staleTotalHelp = """
    The sensors briefly disagreed, so these are the last rows that added up, \
    shown against the total they add up to rather than the current one.
    """

    @ViewBuilder
    private var componentSection: some View {
        if let breakdown = monitor.componentBreakdown, !breakdown.readings.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Components")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    componentTotal(breakdown)
                }
                readingGrid(breakdown.readings)
            }
        }
    }

    /// Staleness dims the total, but dimming is the weakest of the three
    /// signals here: it also earns a symbol when colour and contrast are not
    /// to be relied on, and it is spoken as part of the accessibility value.
    private func componentTotal(_ breakdown: ComponentBreakdown) -> some View {
        HStack(spacing: 3) {
            if breakdown.isStale && differentiateWithoutColor {
                Image(systemName: "clock.badge.exclamationmark")
            }
            Text(String(format: "avg %.1f W", breakdown.totalWatts))
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(breakdown.isStale ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
        .help(Self.componentTotalHelp)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Components total")
        .accessibilityValue(
            String(format: "average %.1f watts", breakdown.totalWatts)
                + (breakdown.isStale ? ", stale" : "")
        )
        .accessibilityHint(breakdown.isStale ? Self.staleTotalHelp : Self.componentTotalHelp)
    }

    @ViewBuilder
    private var appSection: some View {
        Divider()
        VStack(alignment: .leading, spacing: 6) {
            Text("Apps (Estimated)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !monitor.appReadings.isEmpty {
                readingGrid(monitor.appReadings)
            } else if monitor.hasAppSample {
                Text("No measurable app draw")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Estimating…")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func readingSection(_ title: String, readings: [PowerMonitor.Reading]) -> some View {
        if !readings.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                readingGrid(readings)
            }
        }
    }

    private static let rowHelp: [String: String] = [
        "_other": """
        Power WattBar can't attribute to a specific app, so apps plus this \
        row add up to the system total:
        • The machine's fixed baseline: display backlight, SSD, radios, \
        speakers, and idle conversion losses.
        • GPU, Neural Engine, and Media Engine power, which have no \
        per-app counters.
        • CPU time from privileged system processes (Spotlight indexing, \
        WindowServer, security daemons), from processes that started and \
        exited between two updates, and from the kernel.
        """,
        "Display": """
        The SoC's display engines, which composite and drive the internal \
        and external screens. The panel's backlight has no readable power \
        counter and stays in Rest of System.
        """,
        "Media Engine": """
        Fixed-function media hardware: video encode/decode, the camera \
        image processor, and the media scaler.
        """,
        "Fabric & I/O": """
        The on-chip interconnect between SoC blocks, plus the PCIe links \
        to devices like the SSD and Wi-Fi. Covers the links only — the \
        devices themselves stay in Rest of System.
        """,
        "_rest": """
        Power with no readable counter: display backlight, SSD, \
        wifi/bluetooth, speakers, fans, and power-conversion losses. \
        Computed as the system total minus every component above.
        """,
        "PDTR": """
        Total power delivered by the power adapter. While the battery is \
        charging this includes the charge power, so it can be much higher \
        than system power.
        """,
        "PPBR": """
        Power drawn from the battery to run the system. While the battery \
        is charging, shows the power flowing into it instead.
        """,
    ]

    private func readingGrid(_ readings: [PowerMonitor.Reading]) -> some View {
        let hasDetail = readings.contains { $0.detail != nil }
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(readings) { reading in
                GridRow {
                    rowLabel(reading)
                    if hasDetail {
                        Text(reading.detail ?? "")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                            .gridColumnAlignment(.trailing)
                    }
                    Text(String(format: reading.watts < 0.095 ? "%.2f W" : "%.1f W", reading.watts))
                        .monospacedDigit()
                        .gridColumnAlignment(.trailing)
                }
            }
        }
        .font(.callout)
    }

    private func rowLabel(_ reading: PowerMonitor.Reading) -> some View {
        HStack(spacing: 4) {
            Text(reading.label)
                .foregroundStyle(.secondary)
                // One line keeps the grid tidy, but at accessibility sizes a
                // single line truncates most app names to nothing readable.
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .truncationMode(.tail)
            if let help = Self.rowHelp[reading.id] {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help(help)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
