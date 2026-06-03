#if os(macOS)
import SwiftUI

/// 中栏（spec v2 §9）：选中 crew 的**群聊会话页**（白板 + 沟通渠道）。
///
/// crew 元数据 / 机长 / DAG / 责任比例从这里搬到了 `CrewDetailInspector`
/// (顶栏 ⓘ 打开)。「服务端 session」viewer 仍从顶栏进。新建/常驻 session 在
/// 右栏（`CrewSessionWindowView`）。
struct CrewCenterView: View {
    @EnvironmentObject private var crewStore: CrewStore
    @EnvironmentObject private var sessionRunner: CrewSessionRunner
    @State private var showingDetail = false
    @State private var showingRemoteSessions = false

    var body: some View {
        Group {
            if let detail = crewStore.selectedDetail {
                CrewChatView(crewId: detail.crew.id, crewTitle: detail.crew.title)
            } else if let id = crewStore.selectedCrewId, crewStore.loadingDetailIds.contains(id) {
                ProgressView("加载 crew 详情…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if crewStore.selectedCrewId != nil {
                empty("详情加载中…")
            } else {
                empty("在左侧选一个 crew，或者点 \"+\" 新建一个。")
            }
        }
        .toolbar {
            if let detail = crewStore.selectedDetail {
                ToolbarItem(placement: .principal) {
                    Text(detail.crew.title).font(.headline)
                }
                ToolbarItem {
                    Button { showingDetail = true } label: {
                        Label("crew 详情", systemImage: "info.circle")
                    }
                }
                ToolbarItem {
                    Button { showingRemoteSessions = true } label: {
                        Label("服务端 session", systemImage: "rectangle.on.rectangle.angled")
                    }
                }
                ToolbarItem {
                    Button { Task { await crewStore.refreshDetail(detail.crew.id) } } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .sheet(isPresented: $showingDetail) {
            if let detail = crewStore.selectedDetail {
                CrewDetailInspector(detail: detail)
            }
        }
        .sheet(isPresented: $showingRemoteSessions) {
            if let detail = crewStore.selectedDetail {
                RemoteSessionsView(crewId: detail.crew.id, crewTitle: detail.crew.title)
            }
        }
    }

    private func empty(_ text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
