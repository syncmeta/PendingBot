import Foundation

struct BotPick: Identifiable, Hashable {
    let id: String
    let display_name: String
    let model_id: String?
    let visibility: String?
    let creator_id: String?
    let voice_call_enabled: Bool?
    /// When this bot was added (user_bot_contacts.added_at), epoch
    /// seconds. Drives the "按加好友时间" sort; 0 when unknown (e.g. a
    /// pre-v7 cached row before the network refresh lands).
    var addedAt: Int = 0
}
