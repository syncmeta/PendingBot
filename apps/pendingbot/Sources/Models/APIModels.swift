import Foundation

// All response shapes the iOS app reads from the server. Field names mirror
// the SQLite column names the server returns (snake_case) so we use
// CodingKeys where Swift wants camelCase.

struct Bot: Codable, Identifiable, Hashable {
    let id: String
    let display_name: String
    let access_mode: String?
    /// The bot's default model (bots.model_id). For private bots the
    /// owner can change it via PATCH /v1/bots/:id. Resolved to a friendly
    /// name via `ModelCatalog`.
    let model: String?
    /// Visibility — drives the 私有/公有机器人 tag in friend + message lists.
    /// `private` | `public_invite`. (public_open was removed in
    /// 20260527091508_drop_public_open_visibility.) Optional so older
    /// payloads that pre-date 0002_bot_visibility decode without breaking.
    let visibility: String?
    /// User who created this bot. NULL for system preset bots. Used to tell
    /// the creator they may edit/delete (private) or toggle visibility (public).
    let creator_id: String?
    /// Voice-call gate — when true the conversation header shows a phone
    /// button. Optional in the payload so pre-migration payloads decode.
    let voice_call_enabled: Bool?

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
    /// Most recent message row id from `user_unread_counts`.
    var last_message_id: String? = nil

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
    let message_seq: Int?
    let attachments: [Attachment]?
    /// Optimistic-send state for locally-inserted user rows. nil for any
    /// canonical row (loaded from server / Realtime / cache) and for bot
    /// bubbles. "sending" while the HTTP request is in flight (lighter
    /// green bubble), "sent" once the server returned 200 but before the
    /// canonical row arrives (full green, same as nil), "failed" if a
    /// step errored before the canonical row arrived (red bubble + alert).
    /// Drives the bubble background tint in BubbleView.
    let status: String?
    /// Arena fields (loaded in loadHistory; nil on optimistic / realtime /
    /// streamed rows until the next history load). `parent_message_id` links
    /// a bot answer to the user prompt it answers; `bubble_group_id` is the
    /// answer's identity (one answer = one group, possibly many bubbles);
    /// `model_slug` is the model that produced this bot bubble. Together they
    /// drive the inline blind A/B compare for arena turns.
    var parent_message_id: String? = nil
    var bubble_group_id: String? = nil
    var model_slug: String? = nil

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
    var isSent: Bool { status == "sent" }

    func withMessageSeq(_ seq: Int?) -> ChatMessage {
        ChatMessage(
            id: id,
            conversation_id: conversation_id,
            sender_type: sender_type,
            sender_id: sender_id,
            content: content,
            created_at: created_at,
            message_seq: seq,
            attachments: attachments,
            status: status,
            parent_message_id: parent_message_id,
            bubble_group_id: bubble_group_id,
            model_slug: model_slug
        )
    }

    init(id: String,
         conversation_id: String,
         sender_type: String,
         sender_id: String,
         content: String,
         created_at: Int,
         message_seq: Int? = nil,
         attachments: [Attachment]?,
         status: String? = nil,
         parent_message_id: String? = nil,
         bubble_group_id: String? = nil,
         model_slug: String? = nil) {
        self.id = id
        self.conversation_id = conversation_id
        self.sender_type = sender_type
        self.sender_id = sender_id
        self.content = content
        self.created_at = created_at
        self.message_seq = message_seq
        self.attachments = attachments
        self.status = status
        self.parent_message_id = parent_message_id
        self.bubble_group_id = bubble_group_id
        self.model_slug = model_slug
    }

    static func timelinePrecedes(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        if let lseq = lhs.message_seq, let rseq = rhs.message_seq, lseq != rseq {
            return lseq < rseq
        }
        if lhs.created_at != rhs.created_at {
            return lhs.created_at < rhs.created_at
        }
        return lhs.id < rhs.id
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
    /// Original filename — set for non-image files so the bubble can
    /// render an icon+name chip. nil for images (rendered from bytes).
    var filename: String? = nil

    /// True when this attachment should render as an inline image.
    var isImage: Bool { mime.lowercased().hasPrefix("image/") }
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


struct LMArenaScore: Codable, Hashable {
    let rating: Double?
    let rank: Int?
    let vote_count: Int?
    let category: String?
    let leaderboard_publish_date: String?
}

struct OpenRouterModel: Codable, Identifiable, Hashable {
    let slug: String
    let display_name: String
    let provider: String
    let release_date: String?
    let context_length: Int?
    /// True when the model accepts image input. Server derives this from
    /// OpenRouter's architecture.input_modalities. Optional for backwards
    /// compat with cached responses from older builds — treat nil as
    /// "unknown/no" (we can't show it in a vision-only filter).
    let supports_vision: Bool?
    /// Which catalog this row came from: "openrouter" (default) or
    /// "openai" (OpenAI's native list via the AI Gateway). nil → openrouter.
    let source: String?
    /// bots.model_provider to store when this row is picked. nil → default.
    let model_provider: String?
    /// Our canonical local slug when this model is curated locally;
    /// nil for OpenRouter rows we don't register. ModelCatalog indexes by
    /// this too so a bot storing the local slug still resolves.
    let local_slug: String?
    /// USD per 1M tokens, blended 7:2:1 (cache_hit/input/output). nil when
    /// no priced alias is registered. Surfaced as the "Nx" price multiplier.
    let blended_usd_per_million: Double?
    /// LMArena metadata from lmarena-ai/leaderboard-dataset on Hugging Face.
    let lmarena_license: String?
    let lmarena_organization: String?
    let lmarena_scores: [String: LMArenaScore]?
    /// Unique across both catalogs — the same model can appear once per
    /// source (e.g. OpenRouter "openai/gpt-5.5" and native "gpt-5.5").
    var id: String { "\(source ?? "openrouter"):\(slug)" }
}

struct UploadResponse: Codable {
    let id: String
    let url: String
    let mime: String
    let size: Int
    let width: Int?
    let height: Int?
    /// Original filename echoed back by /v1/upload. nil for legacy
    /// responses / image uploads where the name doesn't matter.
    let filename: String?
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

// MARK: - Model Pool (随机模型 / 盲选 / 个人榜单)

/// Bot-level model pool config — mirrors the edge `bots.config.modelPool` jsonb.
/// nil/absent means the bot uses its single model_id. Present means new
/// conversations draw a main model from the price-range pool ∪ explicit
/// `models`, minus `exclude`.
struct RandomModelConfig: Codable, Equatable, Hashable {
    var price_min: Double?
    var price_max: Double?
    var models: [String]?
    var exclude: [String]?
    var vendors: [String]?
    var release_window_days: Int?
    /// Selected model-preset slugs (`model_presets.slug`). The edge expands
    /// these into a model union at chat time (see edge `pickRandomModel`).
    /// nil/empty = no preset refs (an explicit / custom pool, or single model).
    /// Defaulted so the memberwise init stays source-compatible with the
    /// explicit-pool call sites that don't carry presets.
    var presets: [String]? = nil
}

/// One model preset returned by `GET /v1/model-presets`. The edge resolves
/// each preset's rule (旗舰 / 最新 / 最热门 / 速度快 …) against the live
/// OpenRouter catalog, so `models` is the concrete, already-resolved set the
///新建机器人 first screen shows. Bots store only the `slug` (in
/// `RandomModelConfig.presets`); the union is re-resolved server-side per turn.
struct ModelPreset: Codable, Identifiable, Hashable {
    let slug: String
    let title: String
    let description: String
    let default_selected: Bool
    let models: [Entry]

    var id: String { slug }

    struct Entry: Codable, Hashable {
        let slug: String
        let display_name: String
        let provider: String
    }
}

/// Conversation-level model state — returned by `GET /v1/conversations/:id/model`.
/// Drives the header pill's 盲盒 behavior: when `reveal_mode == "surprise"` and
/// `model_revealed == false`, the pill shows "PendingModel" instead of the drawn
/// model's friendly name.
struct ConvModelState: Codable, Equatable {
    let current_model_slug: String?
    let current_model_provider: String?
    let model_revealed: Bool
    let reveal_mode: String      // "surprise" | "disclose"
    let regen_reroll: Bool
    let has_pool: Bool
}

/// Result of revealing / guessing the blind-box model. `correct == nil` means
/// the user gave up rather than guessing.
struct RevealResult: Codable {
    let actual_slug: String
    let actual_provider: String?
    let correct: Bool?           // nil = gave up
}
