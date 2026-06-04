#if os(macOS)
import SwiftUI

/// T0.1 — macOS 好友 tab（#212）。中列两段列表:机器人(已加 bot)+ 好友(人类
/// contacts),逻辑复用跨平台 `FriendsDataSource`。第一版只读展示;点击进会话 /
/// 加好友 / 头像图片 / 备注编辑 留 follow-up。
struct MacFriendsColumn: View {
    /// 点击一个 bot → 打开它的会话(切到消息 tab 选中)。
    var onOpenConversation: (String) -> Void

    @State private var humans: [HumanContact] = []
    @State private var bots: [BotContact] = []
    @State private var loadError: String?
    @State private var notice: String?
    @State private var didLoad = false

    // 加好友 / 建机器人 / 管机器人(#212 Mac 原生重画)。
    @State private var showingAddFriend = false
    @State private var showingAddBot = false
    @State private var showingCreateBot = false
    /// 选中一个自己创建的 bot → 管理 sheet。
    @State private var managingBot: MacBotPick?

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

            // 分区标题字体对齐 iOS Section header 语气(serif 小标题)。
            Section {
                if bots.isEmpty && didLoad {
                    Text("还没有添加机器人")
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
                ForEach(bots) { bot in
                    Button { openBot(bot) } label: {
                        MacFriendRow(
                            avatar: AnyView(BrandAvatar(seed: bot.id, size: 36)),
                            name: bot.displayName,
                            trailing: AnyView(MacBotVisibilityTag(visibility: bot.visibility))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("打开会话") { openBot(bot) }
                        // 管理只对自己创建的 bot 有意义;开管理前拉一次 bots 行
                        // 确认 creator_id == 我,再 seed MacBotPick。RLS 也会
                        // 兜底(非创建者 UPDATE/DELETE 会被拒)。
                        Button("管理机器人…") { Task { await openManage(bot) } }
                    }
                }
            } header: {
                Text("机器人")
                    .font(Theme.Fonts.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.inkMuted)
            }

            Section {
                if humans.isEmpty && didLoad {
                    // 逐字对齐 iOS 好友空态文案(FriendsTabView.emptyTextForFilter
                    // 的 .humans 分支)。
                    Text("还没有人类朋友")
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
                ForEach(humans) { human in
                    MacFriendRow(
                        avatar: AnyView(MacContactAvatar(avatarPath: human.avatarPath,
                                                         seed: human.avatarSeed, size: 36)),
                        name: human.shownName,
                        trailing: AnyView(MacHumanKindTag())
                    )
                }
            } header: {
                Text("好友")
                    .font(Theme.Fonts.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.inkMuted)
            }
        }
        .navigationTitle("好友")
        .toolbar {
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

    /// Resolve a tapped bot's full row (creator_id / model_id / visibility) and,
    /// if the current user created it, open the manage sheet. Otherwise surface
    /// a notice — non-creators can't manage (RLS would reject anyway).
    private func openManage(_ bot: BotContact) async {
        notice = nil
        struct Row: Decodable {
            let id: String
            let display_name: String
            let model_id: String?
            let visibility: String?
            let creator_id: String?
        }
        do {
            let row: Row = try await SupabaseStack.shared
                .from("bots")
                .select("id, display_name, model_id, visibility, creator_id")
                .eq("id", value: bot.id)
                .single()
                .execute()
                .value
            let me = AccountStore.shared.current?.id
            guard let creator = row.creator_id, creator == me else {
                notice = "只有创建者本人能管理「\(bot.displayName)」"
                return
            }
            managingBot = MacBotPick(
                id: row.id,
                displayName: row.display_name,
                modelId: row.model_id,
                visibility: row.visibility,
                creatorId: row.creator_id
            )
        } catch {
            notice = error.localizedDescription
        }
    }

    private func load() async {
        // cache-first:首屏先从共享 LocalDatabase 读上次的 bot / 好友列表即时渲染
        // (对齐 iOS FriendsTabView.load 的 hydrate),再让网络刷新覆盖。首屏 fallback
        // only —— 仅在两列都空时填,避免热屏刷新把新数据回退到缓存。bot 缓存以
        // newest-first 呈现(对齐 listBotContacts 的 reversed())。
        if bots.isEmpty && humans.isEmpty {
            let cachedBots = LocalDatabase.shared.loadBots()
            let cachedContacts = LocalDatabase.shared.loadContacts()
            if !cachedBots.isEmpty {
                bots = cachedBots
                    .filter { !($0.id.hasPrefix("self-")) }
                    .reversed()
                    .map { BotContact(id: $0.id,
                                      displayName: $0.display_name.isEmpty ? "未命名机器人" : $0.display_name,
                                      visibility: $0.visibility) }
            }
            if !cachedContacts.isEmpty {
                humans = cachedContacts.map {
                    HumanContact(id: $0.id, displayName: $0.display_name, alias: $0.alias,
                                 avatarPath: $0.avatar_path, avatarSeed: $0.avatar_seed ?? $0.id)
                }
            }
        }

        // 两个数据源独立拉,任一失败不挡另一个。
        //
        // 缓存策略:只读不写。bot/contact 缓存是 iOS 写入的富行(model_id /
        // creator_id / added_at / avatar_seed),iOS 侧 ownsBot / 模型标签 / 排序
        // 都依赖这些列。Mac 的 FriendsDataSource 只投影 id/display_name/visibility,
        // 若在此整表 replaceBots/replaceContacts 会把 iOS 的列抹成 null(共享单机
        // 缓存),破坏 iOS。所以 Mac 只 hydrate-on-read,写回交给 iOS。
        async let humansResult = FriendsDataSource.listHumanContacts()
        async let botsResult = FriendsDataSource.listBotContacts()
        do { humans = try await humansResult } catch { loadError = error.localizedDescription }
        do { bots = try await botsResult } catch { if loadError == nil { loadError = error.localizedDescription } }
        didLoad = true
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
}

// MARK: - Friend row (对齐 iOS FriendsTabView.FriendRow)

/// 头像 + 名称 + 右侧类型 pill 的好友/机器人行。排版逐项对齐 iOS `FriendRow`:
/// 36pt 头像、`serif(16, .semibold)` ink 名称、行内 10pt 垂直 padding、右侧
/// 满色 tag pill。avatar / trailing 用 `AnyView` 抹平 bot(BrandAvatar +
/// 机器人 visibility pill)与 human(头像 + 人类 pill)两种来源。
private struct MacFriendRow: View {
    let avatar: AnyView
    let name: String
    let trailing: AnyView

    var body: some View {
        HStack(spacing: 10) {
            avatar
            Text(name)
                .font(Theme.Fonts.serif(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 4)
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
