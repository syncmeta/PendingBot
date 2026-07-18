#if os(macOS)
import SwiftUI

/// 驾驶舱「Todo」段的人类 Todo 列表（task #487；原 #478 的右栏 inspector 面板挪入）。
///
/// 每 crew 一个 todo 列表：**只有人类能加条目** —— 新增入口在群聊 composer 的
/// Todo 切换按钮（CrewChatView：点亮后发送 = 创建，群里出「To do +1: #N」）；
/// MCP 不暴露新增工具。机器人经 `respond_todo` 追加回应 + 推进状态
/// （待办 → 进行中 → 完成），回应以时间序缩进显示在条目下。
///
/// 数据层 `LocalTodoStore`：本进程人类新增即推；机器人回应来自 helper 子进程
/// （跨进程写盘），由 `todoChanges` 合流的目录监听补齐 —— 列表即时刷新，无轮询。
struct CrewTodoPanel: View {
    let crewId: String

    @State private var todos: [LocalTodoItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Todo \(todos.count)")
                .font(Theme.Fonts.caption.weight(.semibold))
                .foregroundStyle(Theme.Palette.inkMuted)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            if todos.isEmpty {
                Text("还没有条目 —— 在群聊输入框点亮 Todo 按钮，发送即记一条。")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(todos) { todoRow($0) }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 首拉 + 订阅变更（人类新增本进程即推；机器人回应经目录监听跨进程补齐）。
        .task(id: crewId) {
            todos = LocalTodoStore.shared.list(crewId: crewId)
            for await _ in LocalTodoStore.shared.todoChanges(crewId: crewId) {
                todos = LocalTodoStore.shared.list(crewId: crewId)
            }
        }
    }

    // MARK: - 行渲染

    @ViewBuilder
    private func todoRow(_ item: LocalTodoItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("#\(item.number)")
                    .font(Theme.Fonts.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.Palette.inkMuted)
                statusBadge(item.status)
                Text(item.text)
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(item.status == "completed"
                                     ? Theme.Palette.inkMuted : Theme.Palette.ink)
                    .strikethrough(item.status == "completed",
                                   color: Theme.Palette.inkMuted)
                    .textSelection(.enabled)
            }
            // 机器人回应（追加式，全量按时间序缩进显示；通常一条一两句，不折叠）。
            ForEach(item.responses) { resp in
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Palette.inkMuted)
                    Text("\(resp.senderName ?? "session:\(resp.sessionId.prefix(6))")：\(resp.text)")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .textSelection(.enabled)
                }
                .padding(.leading, 4)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surfaceMuted.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func statusBadge(_ status: String) -> some View {
        let (fg, bg): (Color, Color) = switch status {
        case "in_progress": (Theme.Palette.accent, Theme.Palette.accentBg)
        case "completed": (Theme.Palette.success, Theme.Palette.accentBg.opacity(0.5))
        default: (Theme.Palette.amber, Theme.Palette.amberBg)
        }
        Text(LocalTodoItem.statusLabel(status))
            .font(Theme.Fonts.caption2)
            .foregroundStyle(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(bg, in: Capsule())
    }
}
#endif
