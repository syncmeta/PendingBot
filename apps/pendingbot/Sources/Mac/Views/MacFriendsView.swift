#if os(macOS)
import SwiftUI

/// macOS 好友 tab（#212）。信息架构对齐 iOS `FriendsTabView`:
///   • 顶部 SelfRow(自己,identity header)
///   • filter pill bar(全部 / 人类 / 私有机器人 / 公有机器人 / 群聊)
///   • 排序菜单(名称 / 最近聊天 / 加好友时间,带方向翻转)
///   • 好友申请分区 + 群邀请分区(inline 同意 / 拒绝,复用共享 `FriendsDataSource`)
///   • 单列合并列表(bot + 人类按 filter/sort 过滤排序后交错),行样式沿用 `MacFriendRow`
///
/// 数据/网络层全部复用跨平台 `FriendsDataSource`(底层走 `BotContactsFetch` /
/// `ContactsFetch` + 与 iOS 逐字一致的 friend-requests / groups/invitations worker
/// 调用),这里只 SwiftUI 原生重画。
struct MacFriendsColumn: View {
    /// 点击一个 bot → 打开它的会话(切到消息 tab 选中)。
    var onOpenConversation: (String) -> Void

    @State private var humans: [HumanContact] = []
    @State private var bots: [BotContact] = []
    @State private var pendingFriendRequests: [FriendRequestContact] = []
    @State private var pendingGroupInvitations: [GroupInvitationContact] = []
    @State private var loadError: String?
    @State private var notice: String?
    @State private var didLoad = false

    // filter / sort —— 对齐 iOS。排序偏好持久化,跟 iOS 一样靠 @AppStorage 存原始串。
    @State private var filter: FriendFilter = .all
    @AppStorage("friendSortFieldRaw") private var sortFieldRaw = FriendSortField.name.rawValue
    @AppStorage("friendSortAscending") private var sortAscending = true
    private var sortField: FriendSortField { FriendSortField(rawValue: sortFieldRaw) ?? .name }
    // friendId ("bot:<id>" / "user:<id>") → 最近聊天 epoch 秒,驱动"按最近聊天"。
    @State private var lastActivity: [String: Int] = [:]

    // 加好友 / 建机器人 / 管机器人(#212 Mac 原生重画)。
    @State private var showingAddFriend = false
    @State private var showingAddBot = false
    @State private var showingCreateBot = false
    /// 选中一个自己创建的 bot → 管理 sheet。
    @State private var managingBot: MacBotPick?

    @EnvironmentObject private var catalog: ModelCatalog

    var body: some View {
        List {
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.Palette.plum)
            }
            if let notice {
                Label(notice, systemImage: "info.circle")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.Palette.inkMuted)
            }

            // Self row —— 钉在顶部,不随 filter 隐藏。Mac 暂无自聊 RPC / QR sheet,
            // 这里只作 identity header(见返回缺口),视觉对齐 iOS SelfRow。
            Section {
                MacSelfRow(
                    avatarSeed: AccountStore.shared.avatarSeed
                        ?? AccountStore.shared.current?.id ?? "?",
                    attachmentId: AccountStore.shared.avatarAttachmentId,
                    name: AccountStore.shared.profileDisplayName
                        ?? AccountStore.shared.current?.displayName ?? "你"
                )
            }

            // Filter pill bar —— 对齐 iOS:5 档 + Theme tag 配色,选中带描边。
            Section {
                MacFilterPillBar(filter: $filter)
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            }

            // 好友申请分区 —— 钉在好友列表上方,inline 同意 / 拒绝。空则不显示。
            if !pendingFriendRequests.isEmpty {
                Section {
                    ForEach(pendingFriendRequests) { req in
                        MacFriendRequestRow(
                            request: req,
                            onAccept: { Task { await respondToRequest(req, accept: true) } },
                            onDecline: { Task { await respondToRequest(req, accept: false) } }
                        )
                    }
                } header: {
                    Text("好友申请")
                        .font(Theme.Fonts.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
            }

            // 群邀请分区 —— 同上,inline 同意 / 拒绝。
            if !pendingGroupInvitations.isEmpty {
                Section {
                    ForEach(pendingGroupInvitations) { invite in
                        MacGroupInvitationRow(
                            invitation: invite,
                            onAccept: { Task { await respondToGroupInvitation(invite, accept: true) } },
                            onDecline: { Task { await respondToGroupInvitation(invite, accept: false) } }
                        )
                    }
                } header: {
                    Text("群邀请")
                        .font(Theme.Fonts.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
            }

            // 单列合并列表 —— bot 与人类按 filter/sort 交错。filter 已做类型收窄,
            // 不再分两段(对齐 iOS 单列 IA)。
            if !friendsForFilter.isEmpty {
                Section {
                    ForEach(friendsForFilter) { item in
                        switch item {
                        case .bot(let bot):
                            Button { openBot(bot) } label: {
                                MacFriendRow(
                                    avatar: AnyView(BrandAvatar(seed: bot.id, size: 36)),
                                    name: bot.displayName,
                                    modelTag: AnyView(MacModelTag(modelSlug: bot.modelId, catalog: catalog)),
                                    trailing: AnyView(MacBotVisibilityTag(visibility: bot.visibility))
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("打开会话") { openBot(bot) }
                                // 管理只对自己创建的 bot 显示(对齐 iOS ownsBot)。
                                if ownsBot(bot) {
                                    Button("管理机器人…") { openManage(bot) }
                                }
                            }
                        case .human(let human):
                            MacFriendRow(
                                avatar: AnyView(MacContactAvatar(avatarPath: human.avatarPath,
                                                                 seed: human.avatarSeed, size: 36)),
                                name: human.shownName,
                                modelTag: AnyView(EmptyView()),
                                trailing: AnyView(MacHumanKindTag())
                            )
                        }
                    }
                }
            }

            // filter 选中但无行时的空态文案 —— 逐字对齐 iOS emptyTextForFilter。
            if didLoad, let emptyText = emptyTextForFilter {
                Section {
                    Text(emptyText)
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
            }
        }
        .navigationTitle("好友")
        .toolbar {
            ToolbarItem { friendSortMenu }
            ToolbarItem {
                Menu {
                    Button { showingAddFriend = true } label: {
                        Label("加好友", systemImage: "person.badge.plus")
                    }
                    Button { showingAddBot = true } label: {
                        Label("加机器人", systemImage: "rectangle.badge.plus")
                    }
                    Divider()
                    Button { showingCreateBot = true } label: {
                        Label("新建机器人", systemImage: "sparkles")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAddFriend) {
            MacAddFriendSheet(onAdded: { Task { await load() } })
        }
        .sheet(isPresented: $showingAddBot) {
            MacAddBotSheet()
        }
        .sheet(isPresented: $showingCreateBot) {
            MacCreateBotSheet(onCreated: { _ in Task { await load() } })
        }
        .sheet(item: $managingBot) { pick in
            MacManageBotSheet(
                onChanged: { Task { await load() } },
                onDeleted: { _ in Task { await load() } },
                initial: pick
            )
        }
        .task { await load() }
    }

    // MARK: - Sort menu

    /// 排序菜单 —— 对齐 iOS friendSortMenu:内嵌 Picker 选字段(带 checkmark),
    /// 下面一行翻转当前字段的方向;切字段重置到该字段的自然默认方向。
    private var friendSortMenu: some View {
        Menu {
            Picker("排序方式", selection: sortFieldBinding) {
                ForEach(FriendSortField.allCases, id: \.self) { field in
                    Label(field.label, systemImage: field.systemImage).tag(field)
                }
            }
            Divider()
            Button {
                sortAscending.toggle()
            } label: {
                Label(sortField.directionLabel(ascending: sortAscending),
                      systemImage: sortAscending ? "arrow.up" : "arrow.down")
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }

    private var sortFieldBinding: Binding<FriendSortField> {
        Binding(
            get: { sortField },
            set: { newValue in
                sortFieldRaw = newValue.rawValue
                sortAscending = newValue.defaultAscending
            }
        )
    }

    // MARK: - Filtering + sorting (对齐 iOS friendsForFilter / sortComparator)

    /// 单列合并 friend 行类型 —— bot 与人类共用一段以便排序交错。
    private enum FriendRowItem: Identifiable, Hashable {
        case bot(BotContact)
        case human(HumanContact)

        var id: String {
            switch self {
            case .bot(let b):   return "bot:\(b.id)"
            case .human(let h): return "user:\(h.id)"
            }
        }
        var sortName: String {
            switch self {
            case .bot(let b):   return b.displayName
            case .human(let h): return h.shownName
            }
        }
        var addedAt: Int {
            switch self {
            case .bot(let b):   return b.addedAt
            case .human(let h): return h.addedAt
            }
        }
    }

    private var friendsForFilter: [FriendRowItem] {
        let items: [FriendRowItem]
        switch filter {
        case .all:
            items = bots.map { .bot($0) } + humans.map { .human($0) }
        case .humans:
            items = humans.map { .human($0) }
        case .privateBots:
            items = bots.filter { $0.visibility == "private" }.map { .bot($0) }
        case .publicBots:
            items = bots.filter { $0.visibility != "private" }.map { .bot($0) }
        case .groups:
            items = []
        }
        return items.sorted(by: sortComparator)
    }

    private func sortComparator(_ a: FriendRowItem, _ b: FriendRowItem) -> Bool {
        func byName() -> Bool {
            let r = a.sortName.localizedStandardCompare(b.sortName)
            if r == .orderedSame { return a.id < b.id }
            return sortAscending ? (r == .orderedAscending) : (r == .orderedDescending)
        }
        switch sortField {
        case .name:
            return byName()
        case .recentChat:
            let la = lastActivity[a.id] ?? 0
            let lb = lastActivity[b.id] ?? 0
            if la == lb {
                return a.sortName.localizedStandardCompare(b.sortName) == .orderedAscending
            }
            return sortAscending ? (la < lb) : (la > lb)
        case .addedTime:
            let aa = a.addedAt
            let ab = b.addedAt
            if aa == ab {
                return a.sortName.localizedStandardCompare(b.sortName) == .orderedAscending
            }
            return sortAscending ? (aa < ab) : (aa > ab)
        }
    }

    /// filter 无行时的占位文案 —— 逐字对齐 iOS emptyTextForFilter。`.all` 不显示。
    private var emptyTextForFilter: String? {
        switch filter {
        case .all:
            return nil
        case .humans:
            return friendsForFilter.isEmpty ? "还没有人类朋友" : nil
        case .privateBots:
            return friendsForFilter.isEmpty ? "还没有私有机器人" : nil
        case .publicBots:
            return friendsForFilter.isEmpty ? "还没有公有机器人" : nil
        case .groups:
            return "还没有群聊"
        }
    }

    /// 当前用户是不是这个 bot 的创建者(预置 bot creator 为 nil)。
    private func ownsBot(_ bot: BotContact) -> Bool {
        guard let me = AccountStore.shared.current?.id, let owner = bot.creatorId
        else { return false }
        return owner == me
    }

    // MARK: - Manage / open

    /// 打开管理 sheet。creator_id / model_id / visibility 已随 `listBotContacts`
    /// 拉回(共享 fetch 的富列),无需再查一次 bots 表;RLS 仍兜底非创建者写。
    private func openManage(_ bot: BotContact) {
        managingBot = MacBotPick(
            id: bot.id,
            displayName: bot.displayName,
            modelId: bot.modelId,
            visibility: bot.visibility,
            creatorId: bot.creatorId
        )
    }

    /// 点 bot → 找它的 1:1 会话 → 切到消息 tab 选中。没有现成会话时提示
    /// (Mac 第一版不在这里建会话)。
    private func openBot(_ bot: BotContact) {
        notice = nil
        Task {
            do {
                if let cid = try await FriendsDataSource.findBotConversation(botId: bot.id) {
                    onOpenConversation(cid)
                } else {
                    notice = "还没有和「\(bot.displayName)」的会话,先在手机端聊一次"
                }
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    // MARK: - Inbox actions

    /// 同意 / 拒绝好友申请 —— 乐观移除 inbox 行,失败回 notice,完成后 load() 对账
    /// (同意会往 user_contacts 写一行,好友列表要拿到)。复用共享 `FriendsDataSource`。
    private func respondToRequest(_ request: FriendRequestContact, accept: Bool) async {
        pendingFriendRequests.removeAll { $0.id == request.id }
        do {
            try await FriendsDataSource.respondToFriendRequest(id: request.id, accept: accept)
        } catch {
            notice = "处理好友申请失败: \(error.localizedDescription)"
        }
        await load()
    }

    private func respondToGroupInvitation(_ invitation: GroupInvitationContact, accept: Bool) async {
        pendingGroupInvitations.removeAll { $0.id == invitation.id }
        do {
            try await FriendsDataSource.respondToGroupInvitation(id: invitation.id, accept: accept)
        } catch {
            notice = "处理群邀请失败: \(error.localizedDescription)"
        }
        await load()
    }

    // MARK: - Load

    private func load() async {
        // cache-first:首屏先从共享 LocalDatabase 读上次的 bot / 好友列表即时渲染
        // (对齐 iOS FriendsTabView.load 的 hydrate),再让网络刷新覆盖。首屏 fallback
        // only —— 仅在两列都空时填,避免热屏刷新把新数据回退到缓存。
        if bots.isEmpty && humans.isEmpty {
            let cachedBots = CacheRepository.cachedBots()
            let cachedContacts = CacheRepository.cachedContacts()
            if !cachedBots.isEmpty {
                bots = cachedBots
                    .filter { !($0.id.hasPrefix("self-")) }
                    .reversed()
                    .map { BotContact(id: $0.id,
                                      displayName: $0.display_name.isEmpty ? "未命名机器人" : $0.display_name,
                                      visibility: $0.visibility,
                                      modelId: $0.model_id,
                                      creatorId: $0.creator_id,
                                      addedAt: $0.added_at ?? 0) }
            }
            if !cachedContacts.isEmpty {
                humans = cachedContacts.map {
                    HumanContact(id: $0.id, displayName: $0.display_name, alias: $0.alias,
                                 avatarPath: $0.avatar_path, avatarSeed: $0.avatar_seed ?? $0.id,
                                 addedAt: $0.added_at ?? 0)
                }
            }
            // 从缓存会话 seed 最近聊天排序键,首屏"按最近聊天"大致对(bot 按 bot_id;
            // user_user 缓存里不带 peer id,等网络补)。缓存会话读走共享 ChatDataSource
            // 门面(与消息 tab 同一条缓存读缝),不再裸碰 LocalDatabase。
            if lastActivity.isEmpty {
                var seeded: [String: Int] = [:]
                for conv in ChatDataSource.cachedConversationRows() {
                    if let botId = conv.bot_id, !botId.isEmpty {
                        seeded["bot:\(botId)"] = max(seeded["bot:\(botId)"] ?? 0, conv.last_activity_at)
                    }
                }
                lastActivity = seeded
            }
        }

        // 各数据源独立拉,任一失败不挡其它。
        //
        // 缓存策略:拉成功就写回(走 CacheRepository 门面,与 iOS 同一条缝)。
        // GRDB 是 per-device 的——每个平台装机各有自己的库文件,互不交叉——所以
        // "写回交给 iOS"在纯 Mac 装机上永远填不满本机缓存(旧注释里"怕抹掉 iOS 富行"
        // 的前提对单机共享库才成立,跨设备根本不共享)。而且这里写回的正是 iOS 写的
        // 那批富列:`listBotContacts` / `listHumanContacts` 底层就是 iOS 用的
        // `BotContactsFetch` / `ContactsFetch`,projected 出的 BotContact /
        // HumanContact 已带齐 modelId/creatorId/visibility/addedAt(bot)与
        // alias/avatarPath/avatarSeed/addedAt(contact),构造正典行无信息损失。
        async let humansResult = FriendsDataSource.listHumanContacts()
        async let botsResult = FriendsDataSource.listBotContacts()
        async let friendReqResult = FriendsDataSource.listIncomingFriendRequests()
        async let groupInviteResult = FriendsDataSource.listIncomingGroupInvitations()

        do {
            humans = try await humansResult
            // 拉成功才整表替换缓存——server 是好友列表的事实源,partial upsert 会
            // 留下已删好友的残留行。失败保留旧缓存(不调 persist)。
            CacheRepository.persistContacts(humans.map {
                LocalDatabase.ContactRow(
                    id: $0.id, alias: $0.alias,
                    display_name: $0.displayName,
                    avatar_path: $0.avatarPath,
                    avatar_seed: $0.avatarSeed,
                    added_at: $0.addedAt
                )
            })
        } catch { loadError = error.localizedDescription }
        do {
            bots = try await botsResult
            // voice_call_enabled 不在 macOS 的 BotContact 投影里(Mac 第一版不画
            // 语音开关),写回时置 nil——读侧把 nil 当"关",与未迁移老行同义,不破坏
            // iOS(iOS 自己的写回路径仍带真值;跨设备库不共享,互不覆盖)。
            CacheRepository.persistBots(bots.map {
                LocalDatabase.BotRow(
                    id: $0.id, display_name: $0.displayName,
                    model_id: $0.modelId, visibility: $0.visibility,
                    creator_id: $0.creatorId,
                    voice_call_enabled: nil,
                    added_at: $0.addedAt
                )
            })
        } catch { if loadError == nil { loadError = error.localizedDescription } }
        // inbox 拉取静默降级(底层失败已返回空数组),不挡好友列表。
        pendingFriendRequests = (try? await friendReqResult) ?? []
        pendingGroupInvitations = (try? await groupInviteResult) ?? []
        lastActivity = await buildActivityMap()
        didLoad = true
    }

    // MARK: - Recent-chat activity (对齐 iOS load 的 activity map)

    private struct ConvActivityRow: Decodable {
        let bot_id: String?
        let conversation_type: String?
        let updated_at: String?
        struct Unread: Decodable { let last_message_at: String? }
        let unread: [Unread]?
        struct Participant: Decodable {
            let participant_type: String
            let participant_id: String
        }
        let participants: [Participant]?

        var activitySeconds: Int {
            if let s = unread?.first?.last_message_at,
               let d = ServerTimestamp.parse(s) { return Int(d.timeIntervalSince1970) }
            if let s = updated_at,
               let d = ServerTimestamp.parse(s) { return Int(d.timeIntervalSince1970) }
            return 0
        }
    }

    /// 把会话行收成 friendId → 最近聊天秒 的 map,键用 "bot:<id>" / "user:<id>"
    /// 与 FriendRowItem.id 对齐。失败返回空 map(只降级"按最近聊天"排序,不挡列表)。
    ///
    /// 这条 `.from("conversations")` 不是缓存实体读,而是一道 activity 投影:它要
    /// unread 的 last_message_at + participants 解出 user_user 对端 id 来拼排序键,
    /// 这些列 `ChatDataSource.listConversations` 的瘦 summary 不暴露(也不该塞进去)。
    /// 与 iOS `FriendsTabView.loadConversationActivity()` 同一条专用查询,故保留直查
    /// (cache 写回不涉及它);要收口需另起一个 activity 门面方法,超出本块范围。
    private func buildActivityMap() async -> [String: Int] {
        let rows: [ConvActivityRow]
        do {
            rows = try await SupabaseStack.shared
                .from("conversations")
                .select("bot_id, conversation_type, updated_at, unread:user_unread_counts(last_message_at), participants:conversation_participants(participant_type, participant_id)")
                .execute()
                .value
        } catch {
            return [:]
        }
        let myId = AccountStore.shared.current?.id ?? ""
        var map: [String: Int] = [:]
        for row in rows {
            let ts = row.activitySeconds
            if let botId = row.bot_id, !botId.isEmpty {
                let key = "bot:\(botId)"
                map[key] = max(map[key] ?? 0, ts)
            }
            if row.conversation_type == "user_user" {
                let otherId = row.participants?.first {
                    $0.participant_type == "user" && $0.participant_id != myId
                }?.participant_id
                if let otherId {
                    let key = "user:\(otherId)"
                    map[key] = max(map[key] ?? 0, ts)
                }
            }
        }
        return map
    }
}

// MARK: - Self row (对齐 iOS SelfRow 的视觉)

/// 钉在顶部的"自己"行。Mac 暂无自聊 RPC / QR sheet,这里只作 identity header
/// (无点击 / 无 QR),视觉对齐 iOS SelfRow:36pt 头像 + serif(16,.semibold) 名称。
private struct MacSelfRow: View {
    let avatarSeed: String
    let attachmentId: String?
    let name: String

    var body: some View {
        HStack(spacing: 10) {
            MacContactAvatar(avatarPath: attachmentId, seed: avatarSeed, size: 36)
            Text(name)
                .font(Theme.Fonts.serif(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Friend row (对齐 iOS FriendsTabView.FriendRow)

/// 头像 + 名称 (+ bot 行内模型标签) + 右侧类型 pill 的好友/机器人行。排版逐项
/// 对齐 iOS `FriendRow`:36pt 头像、`serif(16, .semibold)` ink 名称、行内 4pt
/// 垂直 padding、右侧满色 tag pill。avatar / modelTag / trailing 用 `AnyView`
/// 抹平 bot 与 human 两种来源。
private struct MacFriendRow: View {
    let avatar: AnyView
    let name: String
    let modelTag: AnyView
    let trailing: AnyView

    var body: some View {
        HStack(spacing: 10) {
            avatar
            HStack(spacing: 6) {
                Text(name)
                    .font(Theme.Fonts.serif(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(1)
                modelTag
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 4)
    }
}

/// bot 行内模型标签 —— 逐字 / 逐色对齐 iOS FriendRow 的内联 model tag:
/// 友好模型名 + 价格倍率,inkMuted 字 + surfaceMuted 胶囊底。slug 空则不显示。
private struct MacModelTag: View {
    let modelSlug: String?
    let catalog: ModelCatalog

    var body: some View {
        if let slug = modelSlug, !slug.isEmpty {
            HStack(spacing: 4) {
                Text(catalog.displayName(for: slug))
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let mult = catalog.priceMultiplier(for: slug) {
                    Text(ModelCatalog.formatMultiplier(mult))
                        .foregroundStyle(Theme.Palette.inkMuted.opacity(0.65))
                }
            }
            .font(Theme.Fonts.rounded(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.Palette.surfaceMuted))
        }
    }
}

/// 机器人 visibility tag pill —— 逐字 / 逐色对齐 iOS `BotVisibilityTag`:
/// 私有机器人(plum / plumBg)、公有机器人(amber / amberBg)。传 `bots.visibility`
/// 原值;nil 落到公有样式(schema 默认)。
private struct MacBotVisibilityTag: View {
    let visibility: String?

    var body: some View {
        let isPrivate = visibility == "private"
        let text = isPrivate ? "私有机器人" : "公有机器人"
        let fg: Color = isPrivate ? Theme.Palette.plum : Theme.Palette.amber
        let bg: Color = isPrivate ? Theme.Palette.plumBg : Theme.Palette.amberBg
        Text(text)
            .font(Theme.Fonts.system(size: 10, weight: .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(bg))
    }
}

/// 人类 tag pill —— 逐字 / 逐色对齐 iOS `HumanKindTag`(accent / accentBg)。
private struct MacHumanKindTag: View {
    var body: some View {
        Text("人类")
            .font(Theme.Fonts.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.Palette.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.Palette.accentBg))
    }
}

// MARK: - Inbox rows (对齐 iOS FriendRequestRow / GroupInvitationRow)

/// 一条待处理好友申请,inline 同意 / 拒绝。逐项对齐 iOS `FriendRequestRow`。
private struct MacFriendRequestRow: View {
    let request: FriendRequestContact
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            MacContactAvatar(avatarPath: nil, seed: request.peerAvatarSeed, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(request.peerDisplayName)
                    .font(Theme.Fonts.serif(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(1)
                if let msg = request.message, !msg.isEmpty {
                    Text(msg)
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.Palette.inkMuted)
                        .lineLimit(2)
                } else {
                    Text("想加你为好友")
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
            }
            Spacer(minLength: 8)
            MacInboxActions(onAccept: onAccept, onDecline: onDecline)
        }
        .padding(.vertical, 4)
    }
}

/// 一条待处理群邀请,inline 同意 / 拒绝。逐项对齐 iOS `GroupInvitationRow`。
private struct MacGroupInvitationRow: View {
    let invitation: GroupInvitationContact
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            MacContactAvatar(avatarPath: invitation.inviterAvatarPath,
                             seed: invitation.inviterAvatarSeed, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(invitation.groupTitle)
                    .font(Theme.Fonts.serif(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(1)
                Text("\(invitation.inviterName) 邀请你入群")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .lineLimit(1)
                Text(invitation.billingText)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .lineLimit(3)
            }
            Spacer(minLength: 8)
            MacInboxActions(onAccept: onAccept, onDecline: onDecline)
        }
        .padding(.vertical, 4)
    }
}

/// inbox 行右侧的 拒绝 / 同意 胶囊按钮组 —— 逐字 / 逐色对齐 iOS(同 13pt
/// semibold,拒绝走 inkMuted/surfaceMuted,同意走 white/accent)。
private struct MacInboxActions: View {
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onDecline) {
                Text("拒绝")
                    .font(Theme.Fonts.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.Palette.surfaceMuted))
            }
            .buttonStyle(.plain)
            Button(action: onAccept) {
                Text("同意")
                    .font(Theme.Fonts.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.Palette.accent))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Filter pills (对齐 iOS FriendFilter / FilterPillBar / FilterPill)

/// 五档筛选 —— 逐字 / 逐色对齐 iOS `FriendFilter`。
enum FriendFilter: Hashable, CaseIterable {
    case all, humans, privateBots, publicBots, groups

    var label: String {
        switch self {
        case .all:         return "全部"
        case .humans:      return "人类"
        case .privateBots: return "私有机器人"
        case .publicBots:  return "公有机器人"
        case .groups:      return "群聊"
        }
    }

    /// 选中时的前景色(也用于选中描边)。全部 留 ink。
    var fg: Color {
        switch self {
        case .all:         return Theme.Palette.ink
        case .humans:      return Theme.Palette.accent
        case .privateBots: return Theme.Palette.plum
        case .publicBots:  return Theme.Palette.amber
        case .groups:      return Theme.Palette.ink
        }
    }
}

private struct MacFilterPillBar: View {
    @Binding var filter: FriendFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FriendFilter.allCases, id: \.self) { f in
                    MacFilterPill(
                        filter: f,
                        selected: filter == f,
                        // 全部 选中时其它 pill 也满色亮起表示"都在显示",
                        // 但只有被点中的那颗带 selection 描边(对齐 iOS)。
                        active: filter == f || filter == .all
                    ) {
                        filter = f
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
    }
}

private struct MacFilterPill: View {
    let filter: FriendFilter
    let selected: Bool
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(filter.label)
                .font(Theme.Fonts.system(size: 12, weight: .semibold))
                .foregroundStyle(filter.fg.opacity(active ? 1.0 : 0.55))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(tintFill)
                .clipShape(Capsule())
                .overlay(
                    Capsule().strokeBorder(
                        selected ? filter.fg.opacity(0.5) : Color.black.opacity(0.05),
                        lineWidth: selected ? 1.0 : 0.6
                    )
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var tintFill: some View {
        switch filter {
        case .all:
            Capsule().fill(Color.white.opacity(selected ? 0.85 : 0.4))
        case .humans:
            Capsule().fill(Theme.Palette.accentBg.opacity(active ? 1.0 : 0.4))
        case .privateBots:
            Capsule().fill(Theme.Palette.plumBg.opacity(active ? 1.0 : 0.4))
        case .publicBots:
            Capsule().fill(Theme.Palette.amberBg.opacity(active ? 1.0 : 0.4))
        case .groups:
            // tri-tone wash:三种 tag-bg L→R 混合,刻意调淡读作"全部类别"。
            let base = active ? 0.55 : 0.28
            Capsule().fill(
                LinearGradient(
                    colors: [
                        Theme.Palette.accentBg.opacity(base),
                        Theme.Palette.amberBg.opacity(base),
                        Theme.Palette.plumBg.opacity(base),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
    }
}

// MARK: - Sort (对齐 iOS FriendSortField)

/// 合并好友列表的排序字段 —— 逐字对齐 iOS `FriendSortField`。方向(A→Z / Z→A、
/// 旧→新 / 新→旧)由独立 `sortAscending` flag 翻转。
enum FriendSortField: String, CaseIterable {
    case name        // 名称 (pinyin-aware)
    case recentChat  // 最近聊天
    case addedTime   // 加好友时间

    var label: String {
        switch self {
        case .name:       return "名称"
        case .recentChat: return "最近聊天"
        case .addedTime:  return "加好友时间"
        }
    }

    var systemImage: String {
        switch self {
        case .name:       return "textformat"
        case .recentChat: return "bubble.left.and.bubble.right"
        case .addedTime:  return "person.badge.clock"
        }
    }

    var defaultAscending: Bool {
        switch self {
        case .name:                  return true
        case .recentChat, .addedTime: return false
        }
    }

    func directionLabel(ascending: Bool) -> String {
        switch self {
        case .name:       return ascending ? "A→Z" : "Z→A"
        case .recentChat: return ascending ? "最早优先" : "最近优先"
        case .addedTime:  return ascending ? "最早添加" : "最近添加"
        }
    }
}

/// Contact avatar: real uploaded image (auth-gated `ServerImage`) when an
/// avatarPath exists, else the emoji placeholder (`BrandAvatar`). Reuses the
/// same cross-platform `ServerImage` loader iOS uses for chat attachments.
struct MacContactAvatar: View {
    let avatarPath: String?
    let seed: String
    var size: CGFloat = 30

    var body: some View {
        if let avatarPath, !avatarPath.isEmpty {
            ServerImage(path: avatarPath,
                        serverURL: HostedConfig.environment.workerURL,
                        contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            BrandAvatar(seed: seed, size: size)
        }
    }
}
#endif
