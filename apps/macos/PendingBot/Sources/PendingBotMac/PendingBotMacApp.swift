import PendingBotShared
import SwiftUI

@main
struct PendingBotMacApp: App {
    @StateObject private var store = PendingBotMacStore()

    var body: some Scene {
        WindowGroup("PendingBot") {
            PendingBotMacRootView(store: store)
                .frame(minWidth: 1040, minHeight: 680)
        }
        .defaultSize(width: 1180, height: 760)
    }
}
