import PendingBotShared
import SwiftUI

@main
struct PendingBotMacApp: App {
    var body: some Scene {
        WindowGroup("PendingBot") {
            PendingBotBigScreenAppView(crews: PendingBotMacFixtures.crews)
                .frame(minWidth: 1040, minHeight: 680)
        }
        .defaultSize(width: 1180, height: 760)
    }
}

private enum PendingBotMacFixtures {
    static let crews: [PendingBotCrewSummary] = [
        PendingBotCrewSummary(
            id: "crew-local-ops",
            title: "本地执行机组",
            status: "正在整理桌面任务",
            runtimeKind: .local,
            updatedAt: "2026-05-27T09:30:00Z"
        ),
        PendingBotCrewSummary(
            id: "crew-mobile-sync",
            title: "移动同步机组",
            status: "等待 iPad worker 回传",
            runtimeKind: .reservedCloud,
            updatedAt: "2026-05-27T09:10:00Z"
        ),
        PendingBotCrewSummary(
            id: "crew-inbox",
            title: "来信分拣机组",
            status: "本地待命",
            runtimeKind: .local,
            updatedAt: "2026-05-27T08:45:00Z"
        ),
    ]
}
