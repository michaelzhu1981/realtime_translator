import SwiftUI

@main
struct RealtimeTranslatorApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Realtime Translator", systemImage: "captions.bubble") {
            MenuBarView()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
