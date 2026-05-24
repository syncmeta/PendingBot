import SwiftUI

@main
struct PendingCrewApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("PendingCrew") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1040, minHeight: 680)
                .task {
                    await model.bootstrap()
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("刷新") {
                    Task { await model.refreshAll() }
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 520)
        }
    }
}
