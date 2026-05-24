import AppKit
import SwiftUI

@main
struct PendingCrewApp: App {
    @NSApplicationDelegateAdaptor(PendingCrewAppDelegate.self) private var appDelegate
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

final class PendingCrewAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
