#if os(iOS)
import SwiftUI

/// iPad 认证后的根视图 —— NavigationSplitView：
///   sidebar = CrewListView（crew 列表）
///   detail  = CrewChatView（所选群聊）
///
/// 依赖注入清单（runtime crash 防护）：
///   - CrewListView 需要 @EnvironmentObject var crewStore: CrewStore
///   - CrewChatView 需要 @EnvironmentObject var appModel: AppModel
///     （sessionRunner 是 macOS-only，iOS 不需要）
/// 两者均由 WindowGroup → RootView 链路上的 .environmentObject(...) 注入，
/// IPadShell 自身声明同样的 @EnvironmentObject 让 SwiftUI 知道它用到了它们。
struct IPadShell: View {
    @EnvironmentObject private var crewStore: CrewStore
    @EnvironmentObject private var appModel: AppModel

    @State private var selectedCrewId: String?

    var body: some View {
        NavigationSplitView {
            CrewListView(selection: $selectedCrewId)
                .navigationTitle("机组")
        } detail: {
            if let id = selectedCrewId, let title = crewTitle(for: id) {
                CrewChatView(crewId: id, crewTitle: title)
                    .id(id) // 切换 crew 时强制重建 chat view（清空旧 state）
            } else {
                ContentUnavailableView("选择一个机组", systemImage: "person.3")
            }
        }
        .onChange(of: selectedCrewId) { _, id in
            crewStore.selectCrew(id) // selectCrew 是同步方法，接受 String?
        }
    }

    /// 从 crewStore.crews 中找到对应 crew 的 title，供 CrewChatView 初始化用。
    private func crewTitle(for id: String) -> String? {
        crewStore.crews.first(where: { $0.id == id })?.title
    }
}
#endif
