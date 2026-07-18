#if os(macOS)
import SwiftUI

/// 右栏 inspector 的人类 Todo 面板（task #478）。
///
/// 每 crew 一个 todo 列表：**只有人类能加条目**（这里的输入框是唯一新增入口；
/// MCP 不暴露新增工具）；机器人经 `respond_todo` 追加回应 + 推进状态
/// （待办 → 进行中 → 完成），回应以时间序缩进显示在条目下。
///
/// 人类新增时自动发群消息「To do +1: #N xxx」（人类身份、无 @ —— 走与中栏
/// composer 相同的「无 @ 默认给机长」心智：消息落白板后直接唤醒机长来认领）。
///
/// 数据层 `LocalTodoStore`：本进程人类新增即推；机器人回应来自 helper 子进程
/// （跨进程写盘），由 `todoChanges` 合流的目录监听补齐 —— 面板即时刷新，无轮询。
struct TodoInspectorPanel: View {
    let crewId: String
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var sessionRunner: CrewSessionRunner

    @State private var todos: [LocalTodoItem] = []
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Todo \(todos.count)")
                .font(Theme.Fonts.caption.weight(.semibold))
                .foregroundStyle(Theme.Palette.inkMuted)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            if todos.isEmpty {
                Text("给机器人记一条活 —— 每条都会有机器人回应并推进状态。")
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
            composer
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

    // MARK: - 人类新增（唯一入口）

    private var composer: some View {
        HStack(spacing: 6) {
            TextField("加一条 Todo（回车提交）", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(Theme.Fonts.footnote)
                .onSubmit(addTodo)
            Button("添加", action: addTodo)
                .controlSize(.small)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func addTodo() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        let item = LocalTodoStore.shared.add(crewId: crewId, text: text)
        // 自动群消息「To do +1: #N xxx」+ 唤醒机长认领 —— 先落白板再唤醒，
        // 与中栏 composer 的「无 @ 默认给机长」同序（注入的近期上下文 dropLast
        // 正好去掉这条自身）。
        let message = "To do +1: #\(item.number) \(text)"
        let crewId = crewId
        Task {
            try? await appModel.backend?.postCrewMessage(
                crewId: crewId, text: message, mentions: [],
                attachmentIds: [], replyToId: nil)
            wakeCaptain(message: message)
        }
    }

    /// 唤醒机长来认领这条 Todo（对齐 CrewChatView「无 @ 默认给机长」的本地直投）：
    /// 在跑且空闲 → IM 式注入（claude 前置近期群聊上下文）；busy → 不打断（下一轮
    /// 白板注入自然看到）；没在跑 → 拉起机长并带开场 wakeText。
    private func wakeCaptain(message: String) {
        if let run = sessionRunner.runs.first(where: {
            $0.crewId == crewId && $0.role == .captain && $0.status == .running
        }) {
            guard !run.backend.isBusy else { return }
            let recent = Array(LocalWhiteboardStore.shared.list(crewId: crewId).dropLast().suffix(15))
            run.send(CrewLocalMentionInjectLogic.renderInjection(
                messageText: message, senderName: "我",
                recent: run.kind == .claudeCode ? recent : [], imStyle: true))
        } else {
            let crewId = crewId
            Task {
                guard let backend = appModel.backend,
                      let detail = try? await backend.getCrew(crewId) else { return }
                try? await sessionRunner.startCaptain(
                    detail: detail, backend: backend, wakeText: message)
            }
        }
    }
}
#endif
