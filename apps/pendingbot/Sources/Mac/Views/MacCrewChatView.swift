#if os(macOS)
import SwiftUI
import Observation
import Supabase

/// 完整原生 Mac 版 #212 — Crew 群聊(对齐 iOS `CrewDetailV2View` /
/// `CrewChatStore` / `CrewMessageListView` / `CrewComposerBar`)。
///
/// 逻辑全复用跨平台层:`APIClient.getCrewAnnouncements` / `getCrewMembers` /
/// `postCrewMessage`(crew 群聊 wire,刚从 `CrewAPI.swift` 去 iOS 门禁,变跨平台)
/// + `RealtimeManager.startConvChannel`(一个 crew 就是一个 conversation,
/// `crew_announcements` / `crew_sessions` row 变更走同一条 conv 通道实时推)。
/// UI 纯 SwiftUI 原生,气泡观感对齐 `MacChatView`(米白 canvas / 淡绿用户气泡 /
/// 白 bot 气泡 + hairline / 群发送者抬头)。
///
/// iOS 的 `CrewChatStore` 依赖 `GroupBubbleSender`(在 UIKit-coupled 的
/// `BubbleView.swift` 里,iOS-only),没法直接复用;所以这里 hand-port 同一套
/// 适配规则(`sender_session_id != nil` → bot 侧;human member → 用户侧;
/// captain/system → bot 侧)到一个 Mac-native row,渲染由本文件负责。
///
/// 范围(见 docs/tech-debt.md #212):消息流(冷拉 + realtime)+ 乐观发送 +
/// 群发送者抬头 + session 状态条 + 简单 @mention picker。未做:inline 权限卡片
/// (Mac 先把 permission_request 行当系统气泡显示其 summary,记 gap)、附件
/// (crew 群聊 P1 本就无附件)、失败重试 chip(发送失败弹错,留 gap)。

// MARK: - Mac 原生 crew 聊天 store

@MainActor
@Observable
final class MacCrewChatStore {
    let crewId: String
    private let api: APIClient

    /// 一条适配后的群聊行 —— 由 announcement 映射而来的原生渲染单元。
    struct Row: Identifiable, Equatable {
        let id: String
        /// 排序键(epoch 秒)。
        let createdAt: Int
        /// 正文。
        let text: String
        /// 是否画在用户侧(右,淡绿气泡)。human post → 右;agent/captain/system → 左。
        let isMine: Bool
        /// 左侧气泡的发送者名字(右侧 / 无名时为 nil)。
        let senderName: String?
        /// 头像 seed(确定性 emoji)。
        let avatarSeed: String
        /// 乐观发送状态:`sending` / `failed` / nil(已落库)。
        var sendStatus: String?
    }

    private(set) var rows: [Row] = []
    private(set) var sessions: [CrewSessionRow] = []
    private(set) var mentionCandidates: [CrewMentionCandidate] = []
    private(set) var loading = false
    var error: String?

    /// 每次 rows 变更自增,驱动列表滚到底。
    private(set) var revision = 0

    /// 成员 / session 索引,每次冷 load 重建;realtime 单帧用它解析发送者名。
    private var members: CrewMemberIndex?
    private var sessionIndex: CrewSessionIndex?
    private var captainFallback: String?

    private var realtimeToken: ConvSubscriptionToken?

    init(crewId: String, api: APIClient) {
        self.crewId = crewId
        self.api = api
    }

    // MARK: 冷加载

    func load(captainName: String?) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        self.captainFallback = captainName
        do {
            async let annsTask = api.getCrewAnnouncements(crewId)
            async let sessionsTask = api.getCrewSessions(crewId)
            async let membersTask = api.getCrewMembers(crewId)

            let anns = try await annsTask
            let sessionRows = try await sessionsTask
            let memberRows = try await membersTask

            let memberIndex = CrewMemberIndex(members: memberRows, captainFallbackName: captainName)
            let sessIndex = CrewSessionIndex(sessions: sessionRows)
            self.members = memberIndex
            self.sessionIndex = sessIndex

            // 保住在途乐观气泡(sending/failed),冷刷新别把本地行抹掉。
            let pending = rows.filter { $0.sendStatus == "sending" || $0.sendStatus == "failed" }
            var adapted = anns.map { adapt($0, members: memberIndex, sessions: sessIndex) }
            let serverIds = Set(adapted.map(\.id))
            adapted.append(contentsOf: pending.filter { !serverIds.contains($0.id) })
            adapted.sort { $0.createdAt < $1.createdAt }

            self.rows = adapted
            self.sessions = sessionRows
            self.mentionCandidates = Self.buildCandidates(members: memberRows, sessions: sessionRows)
            self.revision += 1
            self.error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: realtime(对齐 iOS CrewChatStore.start/stop)

    func start() async {
        guard realtimeToken == nil, !crewId.isEmpty else { return }
        realtimeToken = await RealtimeManager.shared.startConvChannel(
            conversationId: crewId,
            onMessage: { _ in },
            onCrewAnnouncement: { [weak self] event in
                Task { @MainActor in self?.apply(event) }
            },
            onCrewSession: { [weak self] event in
                Task { @MainActor in self?.applySession(event) }
            }
        )
    }

    func stop() async {
        guard let token = realtimeToken else { return }
        realtimeToken = nil
        await RealtimeManager.shared.stopConvChannel(token)
    }

    private func apply(_ event: CrewAnnouncementEvent) {
        guard let row = Self.decodeAnnouncement(event.record),
              let members, let sessionIndex else { return }
        let newRow = adapt(row, members: members, sessions: sessionIndex)
        if let idx = rows.firstIndex(where: { $0.id == newRow.id }) {
            rows[idx] = newRow
        } else {
            rows.append(newRow)
        }
        rows.sort { $0.createdAt < $1.createdAt }
        revision += 1
    }

    private func applySession(_ event: CrewSessionEvent) {
        guard let row = Self.decodeSession(event.record) else { return }
        if let idx = sessions.firstIndex(where: { $0.id == row.id }) {
            sessions[idx] = row
        } else {
            sessions.append(row)
        }
        revision += 1
    }

    // MARK: 乐观发送

    func send(content: String, mentions: [CrewMentionInput]) async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let localId = "local-\(UUID().uuidString)"
        rows.append(Row(
            id: localId,
            createdAt: Int(Date().timeIntervalSince1970),
            text: trimmed,
            isMine: true,
            senderName: nil,
            avatarSeed: "me-\(crewId)",
            sendStatus: "sending"
        ))
        revision += 1

        do {
            _ = try await api.postCrewMessage(crewId: crewId, content: trimmed, mentions: mentions)
            rows.removeAll { $0.id == localId }
            await load(captainName: captainFallback)
        } catch {
            if let idx = rows.firstIndex(where: { $0.id == localId }) {
                rows[idx].sendStatus = "failed"
            }
            self.error = error.localizedDescription
            revision += 1
        }
    }

    // MARK: 适配规则(hand-port 自 iOS CrewChatAdapter)

    private func adapt(_ row: CrewAnnouncementRow,
                       members: CrewMemberIndex,
                       sessions: CrewSessionIndex) -> Row {
        let epoch = CrewTimestamp.epoch(row.created_at)

        // agent / session post → bot 侧。
        if let sessionId = row.sender_session_id {
            let label = sessions.label(forSession: sessionId) ?? "Session"
            return Row(id: row.id, createdAt: epoch, text: row.summary,
                       isMine: false, senderName: label, avatarSeed: sessionId, sendStatus: nil)
        }

        // human member → 用户侧(P1:所有人类都画右侧,跟 iOS 一致)。
        if members.isHuman(memberId: row.sender_member_id),
           let memberId = row.sender_member_id {
            return Row(id: row.id, createdAt: epoch, text: row.summary,
                       isMine: true, senderName: nil,
                       avatarSeed: members.seed(forMember: memberId) ?? memberId, sendStatus: nil)
        }

        // captain / system / 未解析 → bot 侧。
        let name: String
        let seedId: String
        if let memberId = row.sender_member_id {
            name = members.name(forMember: memberId) ?? captainFallback ?? "机长"
            seedId = memberId
        } else if row.sender_kind == "system" {
            name = "系统"
            seedId = "crew-system-\(crewId)"
        } else {
            name = captainFallback ?? "机长"
            seedId = "crew-captain-\(crewId)"
        }
        return Row(id: row.id, createdAt: epoch, text: row.summary,
                   isMine: false, senderName: name, avatarSeed: seedId, sendStatus: nil)
    }

    // MARK: realtime 帧解码(对齐 iOS CrewChatStore.decode*)

    static func decodeAnnouncement(_ r: [String: AnyJSON]) -> CrewAnnouncementRow? {
        guard let id = r["id"]?.stringValue else { return nil }
        return CrewAnnouncementRow(
            id: id,
            crew_conversation_id: r["crew_conversation_id"]?.stringValue ?? "",
            responsible_subject_id: r["responsible_subject_id"]?.stringValue,
            sender_kind: r["sender_kind"]?.stringValue ?? "system",
            sender_member_id: r["sender_member_id"]?.stringValue,
            sender_session_id: r["sender_session_id"]?.stringValue,
            recipient_mode: r["recipient_mode"]?.stringValue,
            message_kind: r["message_kind"]?.stringValue ?? "text",
            board_visible: r["board_visible"]?.boolValue ?? true,
            summary: r["summary"]?.stringValue ?? "",
            payload: nil,
            created_at: r["created_at"]?.stringValue ?? "",
            mentions: []
        )
    }

    static func decodeSession(_ r: [String: AnyJSON]) -> CrewSessionRow? {
        guard let id = r["id"]?.stringValue else { return nil }
        return CrewSessionRow(
            id: id,
            crew_conversation_id: r["crew_conversation_id"]?.stringValue ?? "",
            responsible_subject_id: r["responsible_subject_id"]?.stringValue,
            runner_kind: r["runner_kind"]?.stringValue,
            status: r["status"]?.stringValue ?? "",
            task_brief: r["task_brief"]?.stringValue,
            progress_summary: r["progress_summary"]?.stringValue,
            created_at: r["created_at"]?.stringValue ?? "",
            started_at: r["started_at"]?.stringValue,
            finished_at: r["finished_at"]?.stringValue
        )
    }

    // MARK: mention 候选(对齐 iOS CrewChatStore.buildCandidates)

    private static func buildCandidates(
        members: [CrewMemberRow],
        sessions: [CrewSessionRow]
    ) -> [CrewMentionCandidate] {
        var out: [CrewMentionCandidate] = []
        for m in members {
            let name = m.display_name?.isEmpty == false ? m.display_name! : String(m.id.prefix(6))
            switch m.member_kind {
            case "human":
                out.append(.init(kind: "human", targetId: m.id, label: name, glyph: "person"))
            case "bot":
                out.append(.init(kind: "captain", targetId: nil, label: name,
                                 glyph: "person.crop.circle.badge.checkmark"))
            default:
                break
            }
        }
        for s in sessions {
            let label = s.task_brief?.isEmpty == false
                ? s.task_brief!
                : CrewSessionIndex.runnerLabel(s.runner_kind ?? "Session")
            out.append(.init(kind: "session", targetId: s.id, label: label, glyph: "terminal"))
        }
        return out
    }
}

/// Mac 端 @mention 候选(跟 iOS `CrewMentionCandidate` 同形,但那个在 iOS-only 的
/// `CrewChatStore.swift` 里,所以这里独立定义一份同名 Mac 版)。
struct CrewMentionCandidate: Identifiable, Hashable {
    let kind: String          // 'human' | 'session' | 'captain'
    let targetId: String?
    let label: String
    let glyph: String
    var id: String { "\(kind)-\(targetId ?? label)" }
    var mentionInput: CrewMentionInput { .init(kind: kind, target_id: targetId) }
}

// MARK: - 群聊视图

struct MacCrewChatView: View {
    let crewId: String
    /// 来自 crew detail 的 captain 名,做 system/captain 气泡的兜底抬头。
    let captainName: String?

    @State private var store: MacCrewChatStore?
    @State private var input = ""
    @State private var staged: [CrewMentionCandidate] = []
    @State private var showPicker = false
    @State private var sending = false

    private let api = APIClient()

    var body: some View {
        VStack(spacing: 0) {
            if let store {
                sessionStrip(store: store)
                transcript(store: store)
                Divider()
                composer(store: store)
            } else {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("加载群聊…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(hex: 0xFDFCFA)) // 对齐 iOS / MacChatView canvas 米白
        .task(id: crewId) { await bootstrap() }
        .onDisappear {
            if let store { Task { await store.stop() } }
        }
    }

    // MARK: session 状态条(对齐 iOS CrewSessionStrip)

    @ViewBuilder
    private func sessionStrip(store: MacCrewChatStore) -> some View {
        if !store.sessions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.sessions) { s in
                        HStack(spacing: 6) {
                            Circle().fill(SessionStatusStyle.tint(s.status)).frame(width: 7, height: 7)
                            Text((s.task_brief?.isEmpty == false) ? s.task_brief!
                                 : CrewSessionIndex.runnerLabel(s.runner_kind ?? "Session"))
                                .font(.caption).lineLimit(1)
                            Text(SessionStatusStyle.statusLabel(s.status))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Color(hex: 0xFFFFFF)))
                        .overlay(Capsule().strokeBorder(Color(hex: 0xE2E0D7), lineWidth: 0.5))
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .background(Color(hex: 0xFDFCFA))
            Divider()
        }
    }

    // MARK: 消息流

    private func transcript(store: MacCrewChatStore) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let err = store.error {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                    if store.rows.isEmpty {
                        emptyState
                    } else {
                        ForEach(store.rows) { row in
                            bubble(row: row).id(row.id)
                        }
                    }
                    Color.clear.frame(height: 1).id("tail")
                }
                .padding(.horizontal, 22).padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: store.revision) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("tail", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func bubble(row: MacCrewChatStore.Row) -> some View {
        let isMine = row.isMine
        HStack(alignment: .top, spacing: 10) {
            if isMine {
                Spacer(minLength: 56)
            } else {
                BrandAvatar(seed: row.avatarSeed, size: 30)
            }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 6) {
                if let name = row.senderName, !isMine {
                    Text(name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color(hex: 0x6E6B5E))
                        .padding(.leading, 4)
                }
                if !row.text.isEmpty {
                    Text(row.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(isMine ? Color(hex: 0xE3EEEA) : Color(hex: 0xFFFFFF))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(isMine ? Color.clear : Color(hex: 0xE2E0D7), lineWidth: 0.5)
                        )
                        .foregroundStyle(Color(hex: 0x1B1A14))
                }
                // 乐观状态尾注:发送中 / 失败。
                if row.sendStatus == "sending" {
                    Text("发送中…").font(.caption2).foregroundStyle(.secondary)
                } else if row.sendStatus == "failed" {
                    Text("发送失败").font(.caption2).foregroundStyle(.red)
                }
            }
            if !isMine { Spacer(minLength: 60) }
        }
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34)).foregroundStyle(.tertiary)
            Text("还没有消息").font(.callout).foregroundStyle(.secondary)
            Text("发条消息或 @机组成员开始协作。")
                .font(.footnote).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    // MARK: composer(对齐 iOS CrewComposerBar)

    private func composer(store: MacCrewChatStore) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if showPicker && !filteredCandidates(store).isEmpty {
                mentionPicker(store: store)
            }
            if !staged.isEmpty {
                stagedChips
            }
            HStack(spacing: 8) {
                TextField("发消息…  输入 @ 提及成员 / session", text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
                    .onSubmit { send(store: store) }
                    .onChange(of: input) { _, newValue in
                        showPicker = newValue.hasSuffix("@")
                    }
                Button {
                    send(store: store)
                } label: {
                    if sending { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(12)
    }

    private func filteredCandidates(_ store: MacCrewChatStore) -> [CrewMentionCandidate] {
        let stagedIds = Set(staged.map(\.id))
        return store.mentionCandidates.filter { !stagedIds.contains($0.id) }
    }

    private func mentionPicker(store: MacCrewChatStore) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(filteredCandidates(store)) { candidate in
                    Button {
                        staged.append(candidate)
                        if input.hasSuffix("@") { input.removeLast() }
                        showPicker = false
                    } label: {
                        Label(candidate.label, systemImage: candidate.glyph)
                            .font(.footnote).lineLimit(1)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(Color(hex: 0xFFFFFF)))
                            .overlay(Capsule().strokeBorder(Color(hex: 0xE2E0D7), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var stagedChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(staged) { candidate in
                    HStack(spacing: 4) {
                        Text("@\(candidate.label)").font(.caption).lineLimit(1)
                        Button {
                            staged.removeAll { $0.id == candidate.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending
    }

    private func send(store: MacCrewChatStore) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        let mentions = staged.map(\.mentionInput)
        sending = true
        input = ""
        staged = []
        showPicker = false
        Task {
            await store.send(content: text, mentions: mentions)
            sending = false
        }
    }

    // MARK: 引导

    private func bootstrap() async {
        let store = MacCrewChatStore(crewId: crewId, api: api)
        self.store = store
        await store.load(captainName: captainName)
        await store.start()
    }
}
#endif
