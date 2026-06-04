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

    @State private var entries: [CrewWhiteboardEntry] = []
    @State private var draft = ""
    @State private var loadError: String?
    @State private var sending = false
    @State private var didInitialLoad = false
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
            CrewComposer(draft: $draft, sending: sending, errorText: loadError) {
                Task { await send() }
            }
        }
        .background(CrewTheme.Palette.canvas)
        .task(id: crewId) { await pollLoop() }
    }

    private var localUserId: String? { nil }   // 见 Step 2 注

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
            CrewBubbleRow(entry: entry, sender: sender)
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
        didInitialLoad = false
        while !Task.isCancelled {
            await refresh()
            didInitialLoad = true
            try? await Task.sleep(nanoseconds: pollInterval)
        }
    }

    private func refresh() async {
        guard let api = try? appModel.loggedAPIClient() else {
            loadError = "未登录"
            return
        }
        do {
            entries = try await api.listCrewWhiteboard(crewId: crewId)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        // Roster is best-effort decoration — a failure leaves the prior strip.
        if let roster = try? await api.listCrewMembers(crewId: crewId) {
            members = roster.members
            captainBotId = roster.captainBotId
        }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let api = try? appModel.loggedAPIClient() else { return }
        sending = true
        defer { sending = false }
        do {
            try await api.postCrewMessage(crewId: crewId, text: text, mentions: [])
            draft = ""
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
