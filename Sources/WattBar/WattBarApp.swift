import SwiftUI

struct WattBarApp: App {
    @State private var monitor = PowerMonitor()

    var body: some Scene {
        MenuBarExtra {
            PowerPanelView(monitor: monitor)
        } label: {
            Text(monitor.menuBarText)
                .monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}
