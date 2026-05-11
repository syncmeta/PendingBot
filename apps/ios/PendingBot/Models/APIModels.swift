import Foundation

// All response shapes the iOS app reads from the server. Field names mirror
// the SQLite column names the server returns (snake_case) so we use
// CodingKeys where Swift wants camelCase.

struct Bot: Codable, Identifiable, Hashable {
    let id: String
    let display_name: String
    let access_mode: String?
    /// The bot's default model (bots.model_id). For private bots the
    /// owner can change it via PATCH /v1/bots/:id; per-conv pins live on
    /// `conversations.model_slug_override` instead. Drives `modelTag` /
    /// `nameWithModel`.
    let model: String?
    /// Visibility — drives the 私有/公有机器人 tag in friend + message lists.
    /// `private` | `public_invite` | `public_open`. Optional so older
    /// payloads that pre-date 0002_bot_visibility decode without breaking.
    let visibility: String?
    /// User who created this bot. NULL for system preset bots. Used to tell
    /// the creator they may edit/delete (private) or toggle visibility (public).
    let creator_id: String?
    /// Voice-call gate — when true the conversation header shows a phone
    /// button. Optional in the payload so pre-migration payloads decode.
    let voice_call_enabled: Bool?

    /// Short tag derived from the OpenRouter slug — drops the provider prefix
    /// so "z-ai/glm-5.1" renders as "glm-5.1". Returns nil when no model is set.
    var modelTag: String? {
        guard let m = model, !m.isEmpty else { return nil }
        if let slash = m.lastIndex(of: "/") {
            return String(m[m.index(after: slash)...])
        }
        return m
    }

    /// Display name with the live model tag appended, e.g. "01 · glm-5.1".
    var nameWithModel: String {
        guard let tag = modelTag else { return display_name }
        return "\(display_name) · \(tag)"
    }
}

struct Conversation: Codable, Identifiable, Hashable {
    let id: String
    let bot_id: String
    let user_id: String
    let title: String?
    let feature_type: String?
    /// Schema's `conversation_type`: user_bot / self / user_user / group.
    /// Drives the list-row badge.
    let conversation_type: String?
    let last_activity_at: Int
    let round_count: Int?
    /// Joined from `bots.display_name` server-side; nil if older row.
    let bot_name: String?
    /// Most recent message text + who sent it (`user` / `bot` / `system`).
    /// Both nil when the conversation has no messages yet.
    let last_message_content: String?
    let last_message_sender_type: String?
    /// Per-conversation model override (OpenRouter slug). nil = use the
    /// bot's configured default.
    let model_override: String?
    /// Per-conversation LLM provider pin (slug from llm_providers, e.g.
    /// "worldrouter" / "openrouter"). nil = follow the bot's default
    /// routing. Sent on every chat POST so this device's choice
    /// propagates server-side; persisted on the row so other devices
    /// see it on their next conversation-list fetch.
    let provider_override: String?

    var displayTitle: String { title?.isEmpty == false ? title! : "未命名" }

    /// One-line preview suitable for an IM-style list row. Empty string
    /// means "no preview to show". Prefixes user-sent previews so the
    /// reader can tell who said it without parsing the layout.
    var previewLine: String {
        let raw = (last_message_content ?? "").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return "" }
        return last_message_sender_type == "user" ? "你: \(raw)" : raw
    }
}

struct ChatMessage: Codable, Identifiable, Hashable {
    let id: String
    let conversation_id: String
    let sender_type: String        // "user" | "bot" | "system"
    let sender_id: String
    let content: String
    let created_at: Int
    let attachments: [Attachment]?
    /// Optimistic-send state for locally-inserted user rows. nil for any
    /// canonical row (loaded from server / Realtime / cache) and for bot
    /// bubbles. "sending" while the conv materialise + SSE turn is in
    /// flight, "failed" if either step errored before the canonical row
    /// arrived. Drives the red/dimmed treatment in BubbleView.
    let status: String?

    /// True only for messages I sent. For user_bot, every sender_type=="user"
    /// row is mine by definition (the bot is the only other side). For
    /// user_user / group, both parties have sender_type=="user", so we have
    /// to compare sender_id against the local account — without this, the
    /// other person's bubbles render right-aligned as if I had sent them.
    func isMine(currentUserId: String?) -> Bool {
        guard sender_type == "user" else { return false }
        guard let me = currentUserId, !me.isEmpty else { return true }
        if sender_id.isEmpty { return true }   // optimistic local bubble pre-id
        return sender_id == me
    }
    var isFailed: Bool { status == "failed" }
    var isSending: Bool { status == "sending" }

    init(id: String,
         conversation_id: String,
         sender_type: String,
         sender_id: String,
         content: String,
         created_at: Int,
         attachments: [Attachment]?,
         status: String? = nil) {
        self.id = id
        self.conversation_id = conversation_id
        self.sender_type = sender_type
        self.sender_id = sender_id
        self.content = content
        self.created_at = created_at
        self.attachments = attachments
        self.status = status
    }
}

struct Attachment: Codable, Identifiable, Hashable {
    let id: String
    let kind: String?
    let mime: String
    let size: Int?
    let width: Int?
    let height: Int?
    let url: String      // relative path, e.g. /uploads/<id>
}

/// One web-search citation attached to a bot message. Stored as a JSON array
/// in `messages.citations`; iOS resolves inline `[N]` markers in the bubble
/// content against this list (1-based) to render tappable chips.
struct MessageCitation: Codable, Hashable, Identifiable {
    let url: String
    let title: String
    let snippet: String?

    /// Identity is the URL — citations are deduped by URL on the server, and
    /// SwiftUI's `.sheet(item:)` wants a stable Identifiable.
    var id: String { url }
}


struct OpenRouterModel: Codable, Identifiable, Hashable {
    let slug: String
    let display_name: String
    let provider: String
    let context_length: Int?
    /// True when the model accepts image input. Server derives this from
    /// OpenRouter's architecture.input_modalities. Optional for backwards
    /// compat with cached responses from older builds — treat nil as
    /// "unknown/no" (we can't show it in a vision-only filter).
    let supports_vision: Bool?
    var id: String { slug }
}

struct UploadResponse: Codable {
    let id: String
    let url: String
    let mime: String
    let size: Int
    let width: Int?
    let height: Int?
}

struct MeProfile: Codable {
    let user_id: String?
    let display_name: String
    let bio: String?
    let avatar_path: String?
    // Verified primary email. Comes from Supabase Auth (auth.users.email).
    let email: String?
}

struct AiPick: Codable, Identifiable, Hashable {
    let id: String
    let user_id: String
    let title: String
    let url: String?
    let summary: String?
    let why_picked: String?
    let created_at: Int?
    let removed_at: Int?
}

// ── Skills ──────────────────────────────────────────────────────────────────

/// Index-row shape returned by `GET /api/skills` — body is omitted for size.
/// `is_preset` flags rows seeded from the bundled anthropic/skills bundle.
struct SkillSummary: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let enabled: Bool
    let source: String?
    let source_url: String?
    let license: String?
    let is_preset: Bool
    let body_length: Int
    let updated_at: Int
}

/// Full skill row including the markdown body. Returned by `GET /api/skills/:id`.
struct SkillDetail: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let enabled: Bool
    let source: String?
    let source_url: String?
    let license: String?
    let is_preset: Bool
    let body_length: Int
    let updated_at: Int
    let body: String
}
