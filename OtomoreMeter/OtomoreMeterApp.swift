import SwiftUI

@main
struct OtomoreMeterApp: App {
    @StateObject private var monitor = AudioMonitor()
    @StateObject private var measurer = Measurer()
    @StateObject private var prefs = UserPrefs()
    @StateObject private var health = HealthLevels()

    var body: some Scene {
        WindowGroup {
            ContentView(monitor: monitor, measurer: measurer, prefs: prefs, health: health)
        }
    }
}
