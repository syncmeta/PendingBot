#if os(macOS)
import SwiftUI

/// 中栏 = crew 群聊会话页（spec v2 §9：群聊 = 沟通渠道 + 白板）。
///
/// - 时间线渲染 crew 白板（`crew_announcements`，经 `listCrewWhiteboard`）。
/// - 底部 composer 发消息（`postCrewMessage`，默认 broadcast = 全 session）。
/// - ask_human 交互卡（`payload.kind == "interaction"`，spec §10.6）就地渲染
///   问题 + 回答框，操作者直接在群聊里答（`answerInteraction`），不必跳别处。
///
/// 详细 IO（stdout/stderr/工具日志）不在这——那在右栏 session 窗口（§9.3）。
struct CrewChatView: View {
    let crewId: String
    let crewTitle: String

    @EnvironmentObject private var appModel: AppModel
    /// MacThreePaneView 注入（经 CrewCenterView）—— session 发的消息点击可
    /// 跳到右栏对应 session（chunk2 T6 中栏跳转）。
    @EnvironmentObject private var sessionRunner: CrewSessionRunner

    @State private var entries: [CrewWhiteboardEntry] = []
    @State private var draft = ""
    @State private var pendingAttachments: [PendingComposerAttachment] = []
    @State private var loadError: String?
    @State private var sending = false
    /// Per-interaction reply drafts, keyed by permission_request_id.
    @State private var replyDrafts: [String: String] = [:]
    /// Crew roster (spec §9 — everyone is a member): rendered as a participant strip.
    @State private var members: [CrewMember] = []
    @State private var captainBotId: String?

    private let pollInterval: UInt64 = 3_000_000_000 // 3s

    var body: some View {
        VStack(spacing: 0) {
            if !members.isEmpty {
                CrewRosterBar(members: members, captainBotId: captainBotId)
                Divider()
            }
            timeline
            Divider()
            CrewComposer(
                draft: $draft,
                attachments: $pendingAttachments,
                sending: sending,
                errorText: loadError
            ) {
                Task { await send() }
            }
        }
        .background(CrewTheme.Palette.canvas)
        .task(id: crewId) { await pollLoop() }
    }

    // 本机用户哨兵 id —— 接合 v2 后 macOS 白板恒为本地，本机人类消息都标
    // `LocalWhiteboardStore.localUserId`，CrewSenderResolver 据此把自己的
    // 消息识别成"自己"(右对齐、无头像)。
    private var localUserId: String? { LocalWhiteboardStore.localUserId }

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if entries.isEmpty { emptyState }
                    ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                        let prevDate = idx > 0 ? CrewTimeSeparator.parse(entries[idx - 1].createdAt) : nil
                        if let cur = CrewTimeSeparator.parse(entry.createdAt),
                           CrewTimeSeparator.needsSeparator(prev: prevDate, cur: cur) {
                            CrewTimeSeparator(date: cur)
                        }
                        rowView(entry).id(entry.id)
                    }
                    Color.clear.frame(height: 1).id("tail")
                }
                .padding(.vertical, 10)
            }
            .onChange(of: entries.count) { _, _ in
                withAnimation(.linear(duration: 0.05)) { proxy.scrollTo("tail", anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func rowView(_ entry: CrewWhiteboardEntry) -> some View {
        if entry.isInteraction {
            let reqId = entry.payload?.permissionRequestId ?? entry.id
            CrewInteractionCard(
                entry: entry,
                reply: Binding(get: { replyDrafts[reqId] ?? "" }, set: { replyDrafts[reqId] = $0 })
            ) { Task { await answer(reqId) } }
        } else {
            let sender = CrewSenderResolver.resolve(entry, members: members,
                                                    captainBotId: captainBotId, localUserId: localUserId)
            // session 发的消息可点 → 右栏切到对应 session（chunk2 T6 中栏跳转）。
            // 找不到对应 run（已移除/别的 crew）则点击无事发生。
            if let senderSessionId = entry.senderSessionId {
                CrewBubbleRow(entry: entry, sender: sender)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let run = sessionRunner.runs.first(where: { $0.sessionId == senderSessionId }) {
                            sessionRunner.select(run.runID)
                        }
                    }
            } else {
                CrewBubbleRow(entry: entry, sender: sender)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34)).foregroundStyle(.tertiary)
            Text("群聊白板 —— 在这里给 session 留指令、看关键节点。\n@session 发给某个 session，不 @ 则广播给全部。")
                .font(CrewTheme.Fonts.callout).foregroundStyle(CrewTheme.Palette.inkMuted)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    // MARK: - data

    private func pollLoop() async {
        entries = []
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(nanoseconds: pollInterval)
        }
    }

    private func refresh() async {
        // 走 backend(双轨):登录态 → edge;BYOK → 本地白板 store。
        guard let backend = appModel.backend else {
            loadError = "未配置 backend"
            return
        }
        do {
            entries = try await backend.listCrewWhiteboard(crewId: crewId)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        // Roster is best-effort decoration — a failure leaves the prior strip.
        if let roster = try? await backend.listCrewMembers(crewId: crewId) {
            members = roster.members
            captainBotId = roster.captainBotId
        }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let toUpload = pendingAttachments
        // Allow attachment-only sends (no text) as long as something is present.
        guard !text.isEmpty || !toUpload.isEmpty,
              let backend = appModel.backend else { return }
        sending = true
        defer { sending = false }
        do {
            // 附件上传是登录后的能力叠加(走 edge 上传)：未登录 → 软报错、不发。
            // 上传走 loggedAPIClient(edge 专属),拿到 ids 再交给 backend 发文。
            var attachmentIds: [String] = []
            if !toUpload.isEmpty {
                guard appModel.isAuthenticated, let api = try? appModel.loggedAPIClient() else {
                    loadError = "群聊附件需登录 PendingBot"
                    return
                }
                for att in toUpload {
                    let id = try await api.uploadAttachment(
                        data: att.data, filename: att.filename, mime: att.mime)
                    attachmentIds.append(id)
                }
            }
            try await backend.postCrewMessage(
                crewId: crewId, text: text, mentions: [], attachmentIds: attachmentIds)
            draft = ""
            pendingAttachments = []
            await refresh()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func answer(_ reqId: String) async {
        let reply = (replyDrafts[reqId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty, let api = try? appModel.loggedAPIClient() else { return }
        do {
            try await api.answerInteraction(reqId: reqId, reply: reply)
            replyDrafts[reqId] = nil
            await refresh()
        } catch {
            loadError = error.localizedDescription
        }
    }
}
#endif
