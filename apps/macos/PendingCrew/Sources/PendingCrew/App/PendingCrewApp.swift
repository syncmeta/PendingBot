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
                .onOpenURL { url in
                    model.openDeepLink(url)
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
        configureOpenWindows()
        DispatchQueue.main.async {
            self.configureOpenWindows()
            NSApp.activate(ignoringOtherApps: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.configureOpenWindows()
        }
    }

    private func configureOpenWindows() {
        for window in NSApp.windows where window.isVisible {
            window.sharingType = .readOnly
            if window.title.isEmpty {
                window.title = "PendingCrew"
            }
            if window.canBecomeKey {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}
