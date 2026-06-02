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
                        HStack(spacing: 8) {
                            Image(systemName: "cpu")
                                .foregroundStyle(.tint)
                                .frame(width: 22)
                            Text(bot.displayName).lineLimit(1)
                            Spacer(minLength: 4)
                            if bot.visibility == "public_invite" {
                                Text("公开").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 1)
                }
            }

            Section("好友") {
                if humans.isEmpty && didLoad {
                    Text("还没有好友").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(humans) { human in
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle")
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        Text(human.shownName).lineLimit(1)
                    }
                    .padding(.vertical, 1)
                }
            }
        }
        .navigationTitle("好友")
        .task { await load() }
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
#endif
