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
                rosterBar
                Divider()
            }
            timeline
            Divider()
            composer
        }
        .task(id: crewId) { await pollLoop() }
    }

    // MARK: - roster (participant strip)

    private var rosterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(members) { m in
                    memberChip(m)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private func memberChip(_ m: CrewMember) -> some View {
        let isCaptain = m.memberKind == "captain" || (m.botId != nil && m.botId == captainBotId)
        let (icon, tint): (String, Color) = {
            if isCaptain { return ("star.circle.fill", .orange) }
            switch m.memberKind {
            case "human": return ("person.crop.circle.fill", .accentColor)
            case "code_session": return ("terminal.fill", .green)
            case "bot": return ("cpu.fill", .purple)
            default: return ("circle.fill", .secondary)
            }
        }()
        return VStack(spacing: 3) {
            Image(systemName: icon).font(.title3).foregroundStyle(tint)
            Text(memberLabel(m, isCaptain: isCaptain))
                .font(.caption2)
                .lineLimit(1)
                .frame(maxWidth: 76)
        }
    }

    private func memberLabel(_ m: CrewMember, isCaptain: Bool) -> String {
        if let n = m.displayName, !n.isEmpty { return n }
        if isCaptain { return "机长" }
        switch m.memberKind {
        case "human": return "我"
        case "code_session": return "session"
        case "bot": return "bot"
        default: return m.memberKind
        }
    }

    // MARK: - timeline

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if entries.isEmpty {
                        emptyState
                    }
                    ForEach(entries) { entry in
                        row(entry).id(entry.id)
                    }
                    Color.clear.frame(height: 1).id("tail")
                }
                .padding(14)
            }
            .onChange(of: entries.count) { _, _ in
                withAnimation(.linear(duration: 0.05)) { proxy.scrollTo("tail", anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func row(_ entry: CrewWhiteboardEntry) -> some View {
        if entry.isInteraction {
            interactionCard(entry)
        } else {
            messageBubble(entry)
        }
    }

    private func messageBubble(_ entry: CrewWhiteboardEntry) -> some View {
        let mine = entry.senderKind == "user"
        return HStack {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                Text(senderLabel(entry))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(entry.displayText)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        mine ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
            }
            if !mine { Spacer(minLength: 40) }
        }
    }

    private func interactionCard(_ entry: CrewWhiteboardEntry) -> some View {
        let reqId = entry.payload?.permissionRequestId
        let pending = (entry.payload?.status ?? "pending") == "pending"
        return VStack(alignment: .leading, spacing: 8) {
            Label("Agent 在问你", systemImage: "person.fill.questionmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
            Text(entry.payload?.question ?? entry.displayText)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if pending, let reqId {
                HStack(spacing: 8) {
                    TextField("回答…", text: Binding(
                        get: { replyDrafts[reqId] ?? "" },
                        set: { replyDrafts[reqId] = $0 }
                    ), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit { Task { await answer(reqId) } }
                    Button("回答") { Task { await answer(reqId) } }
                        .buttonStyle(.borderedProminent)
                        .disabled((replyDrafts[reqId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else if !pending {
                Text("已回答")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.tint.opacity(0.35)))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("群聊白板 —— 在这里给 session 留指令、看关键节点。\n@session 发给某个 session，不 @ 则广播给全部。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - composer

    private var composer: some View {
        VStack(spacing: 4) {
            if let loadError {
                Text(loadError).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                TextField("给 crew 留言…（不 @ = 广播给所有 session）", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .onSubmit { Task { await send() } }
                Button {
                    Task { await send() }
                } label: {
                    if sending { ProgressView().controlSize(.small) }
                    else { Image(systemName: "paperplane.fill") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
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

    private func senderLabel(_ entry: CrewWhiteboardEntry) -> String {
        switch entry.senderKind {
        case "user": return "我"
        case "session":
            if let sid = entry.senderSessionId { return "session · \(sid.prefix(8))" }
            return "session"
        case "bot": return "bot"
        default: return entry.senderKind
        }
    }
}
#endif
