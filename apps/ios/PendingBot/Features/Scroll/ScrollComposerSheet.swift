import SwiftUI

/// Sheet for triggering a new scroll. Lists the user's bot conversations
/// (one row per user_bot conv) — the bot reads from that conv's history
/// and produces an article. Tap a row → fire trigger and dismiss.
struct ScrollComposerSheet: View {
    let onPick: (_ conversationId: String) async -> Void

    @State private var convs: [BotConv] = []
    @State private var loading = true
    @State private var error: String?
    @State private var firingId: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if loading {
                    ProgressView().padding(.top, 80)
                        .frame(maxWidth: .infinity)
                } else if convs.isEmpty {
                    EmptyState()
                } else {
                    List {
                        Section {
                            ForEach(convs) { c in
                                Button {
                                    Task { await fire(c) }
                                } label: {
                                    HStack(spacing: 10) {
                                        BotAvatar(seed: c.bot_id, size: 36)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(c.display_name)
                                                .font(Theme.Fonts.serif(size: 16, weight: .semibold))
                                                .foregroundStyle(Theme.Palette.ink)
                                                .lineLimit(1)
                                            if let preview = c.preview {
                                                Text(preview)
                                                    .font(Theme.Fonts.caption)
                                                    .foregroundStyle(Theme.Palette.inkMuted)
                                                    .lineLimit(1)
                                            }
                                        }
                                        Spacer()
                                        if firingId == c.id {
                                            ProgressView()
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(Theme.Palette.surface)
                                .disabled(firingId != nil)
                            }
                        } header: {
                            Text("从哪只机器人那里听一听？")
                                .font(Theme.Fonts.footnote)
                                .foregroundStyle(Theme.Palette.inkMuted)
                                .textCase(nil)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .navigationTitle("新拟一卷")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .alert("出错", isPresented: .constant(error != nil)) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
        .task { await load() }
    }

    // MARK: - Data

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            // Pull this user's bot conversations + last message preview.
            // Same shape MessageTab uses, scoped to user_bot type.
            // Preview lives on user_unread_counts, not conversations.
            let rows: [ConvRow] = try await SupabaseStack.shared
                .from("conversations")
                .select("""
                    id, bot_id, conversation_type, updated_at,
                    bot:bots(display_name),
                    unread:user_unread_counts(last_message_preview)
                """)
                .eq("conversation_type", value: "user_bot")
                .order("updated_at", ascending: false)
                .limit(50)
                .execute()
                .value
            convs = rows.compactMap { row in
                guard let botId = row.bot_id else { return nil }
                return BotConv(
                    id: row.id,
                    bot_id: botId,
                    display_name: row.bot?.display_name ?? "机器人",
                    preview: row.unread?.first?.last_message_preview
                )
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func fire(_ c: BotConv) async {
        firingId = c.id
        await onPick(c.id)
        firingId = nil
    }

    // MARK: - Models

    struct BotConv: Identifiable, Hashable {
        let id: String
        let bot_id: String
        let display_name: String
        let preview: String?
    }

    private struct ConvRow: Decodable {
        let id: String
        let bot_id: String?
        let bot: BotInline?
        let unread: [UnreadJoin]?
        struct BotInline: Decodable {
            let display_name: String
        }
        struct UnreadJoin: Decodable {
            let last_message_preview: String?
        }
    }

    private struct EmptyState: View {
        var body: some View {
            VStack(spacing: 8) {
                Text("还没有跟任何机器人聊过")
                    .font(Theme.Fonts.serif(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Text("先去「好友」里挑一只机器人聊几轮，再回来拟奏折。")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.Palette.inkMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
