import SwiftUI
import Supabase

/// Read-only viewer for a subagent sub-conversation — the child thread
/// spawned by a parent bot's `delegate_to_specialist` tool call. Reached
/// by tapping the "子对话已生成" chip on a delegate trace row.
///
/// Sub-conversations are small by design (one user-role prompt + one
/// bot-role reply today, with room to grow), so the layout is a plain
/// vertical scroll with the same bubble grammar as the main conv view —
/// no Realtime subscription, no input row, no tool trace of its own.
struct SubConversationView: View {
    /// The pendingbot.conversations row id stamped onto the parent's
    /// tool_result event (`sub_conversation:<uuid>` in resultDetail).
    let subConversationId: String
    /// Specialist label emitted by the parent turn's tool trace. Usually the
    /// target bot's display name; kept as String so new target kinds need no
    /// enum bump.
    let target: String?

    @Environment(\.dismiss) private var dismiss
    @State private var messages: [ChatMessage] = []
    @State private var loading = true
    @State private var error: String?
    @State private var botId: String?
    @State private var botName: String = "专家"
    @State private var currentUserId: String?

    private var serverURL: URL? { AccountStore.shared.current?.workerURL }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.canvas.ignoresSafeArea()
                if loading && messages.isEmpty {
                    ProgressView().tint(Theme.Palette.accent)
                } else if let error, messages.isEmpty {
                    VStack(spacing: 8) {
                        Text("加载子对话失败")
                            .font(Theme.Fonts.rounded(size: 14, weight: .medium))
                            .foregroundStyle(Theme.Palette.ink)
                        Text(error)
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Palette.inkMuted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        Button("重试") { Task { await load() } }
                            .foregroundStyle(Theme.Palette.accent)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            // Quiet header explaining what this view is —
                            // the user landed here via a chip on the parent
                            // trace, so they may not remember they're now
                            // looking at a sibling thread.
                            disclaimer
                            ForEach(messages) { m in
                                BubbleView(
                                    message: m,
                                    botName: botName,
                                    conversationID: subConversationId,
                                    botID: botId,
                                    currentUserId: currentUserId,
                                    serverURL: serverURL
                                ) {
                                    // Empty context menu — sub-conv is
                                    // read-only, no recall / retry / share.
                                    EmptyView()
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .inlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("子对话")
                            .font(Theme.Fonts.serif(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.Palette.ink)
                        if let target {
                            Text("委托给 \(specialistLabel(target))")
                                .font(Theme.Fonts.rounded(size: 11, weight: .regular))
                                .foregroundStyle(Theme.Palette.inkMuted)
                        }
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .foregroundStyle(Theme.Palette.inkMuted)
                }
            }
        }
        .task { await load() }
    }

    private var disclaimer: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(Theme.Fonts.glyph(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Palette.inkMuted)
            Text("这是父机器人为了完成你的请求开启的专家子对话；它不会出现在主聊天列表里。")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.inkMuted)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.Metrics.gutter)
        .padding(.vertical, 6)
    }

    private func specialistLabel(_ target: String) -> String {
        switch target {
        case "claude":  return "Claude"
        case "openai":  return "OpenAI"
        case "gemini":  return "Gemini"
        default:         return target
        }
    }

    // ── Loaders ─────────────────────────────────────────────────────────────

    private struct ConvRow: Decodable {
        let bot_id: String?
        // bot relation embedded inline so we get the display name in one
        // round-trip — same pattern the main conv list uses.
        let bot: EmbeddedBot?
    }
    private struct EmbeddedBot: Decodable {
        let display_name: String?
    }
    private struct MsgRow: Decodable {
        let id: String
        let conversation_id: String
        let user_id: String?
        let sender_bot_id: String?
        let role: String
        let content: String?
        let status: String?
        let created_at: String
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            // The current logged-in user id is needed by BubbleView to
            // decide which side each message lands on. We pull from the
            // SDK's session cache — cheap, no network.
            currentUserId = try? await SupabaseStack.shared.auth.session.user.id.uuidString.lowercased()

            // Fetch conv row (for bot id + name) and message rows in
            // parallel — they share an id key but no FK between them.
            async let conv: ConvRow = SupabaseStack.shared
                .from("conversations")
                .select("bot_id, bot:bots!conversations_bot_id_fkey(display_name)")
                .eq("id", value: subConversationId)
                .single()
                .execute()
                .value
            async let msgs: [MsgRow] = SupabaseStack.shared
                .from("messages")
                .select("id, conversation_id, user_id, sender_bot_id, role, content, status, created_at")
                .eq("conversation_id", value: subConversationId)
                .order("created_at", ascending: true)
                .limit(50)
                .execute()
                .value
            let convRow = try await conv
            let rows = try await msgs
            botId = convRow.bot_id
            if let n = convRow.bot?.display_name, !n.isEmpty { botName = n }
            messages = rows.compactMap { r in
                guard r.status != "deleted" else { return nil }
                let isUser = r.role == "user"
                return ChatMessage(
                    id: r.id,
                    conversation_id: r.conversation_id,
                    sender_type: isUser ? "user" : "bot",
                    sender_id: isUser ? (r.user_id ?? "") : (r.sender_bot_id ?? ""),
                    content: r.content ?? "",
                    created_at: ServerTimestamp.epochSeconds(r.created_at, default: 0),
                    attachments: nil,
                    status: nil
                )
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
