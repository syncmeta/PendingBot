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
                    .font(.caption).foregroundStyle(.red)
            }
            if let notice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("机器人") {
                if bots.isEmpty && didLoad {
                    Text("还没有添加机器人").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(bots) { bot in
                    Button { openBot(bot) } label: {
                        HStack(spacing: 9) {
                            BrandAvatar(seed: bot.id, size: 30)
                            Text(bot.displayName).lineLimit(1)
                            Spacer(minLength: 4)
                            if bot.visibility == "public_invite" {
                                Text("公开").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 5)
                    .contextMenu {
                        Button("打开会话") { openBot(bot) }
                        // 管理只对自己创建的 bot 有意义;开管理前拉一次 bots 行
                        // 确认 creator_id == 我,再 seed MacBotPick。RLS 也会
                        // 兜底(非创建者 UPDATE/DELETE 会被拒)。
                        Button("管理机器人…") { Task { await openManage(bot) } }
                    }
                }
            }

            Section("好友") {
                if humans.isEmpty && didLoad {
                    Text("还没有好友").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(humans) { human in
                    HStack(spacing: 9) {
                        MacContactAvatar(avatarPath: human.avatarPath, seed: human.avatarSeed, size: 30)
                        Text(human.shownName).lineLimit(1)
                    }
                    .padding(.vertical, 5)
                }
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
                        Label("加机器人", systemImage: "plus.bubble")
                    }
                    Divider()
                    Button { showingCreateBot = true } label: {
                        Label("新建机器人", systemImage: "wand.and.stars")
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
        // 两个数据源独立拉,任一失败不挡另一个。
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
