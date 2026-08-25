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
    /// 这个 bot 是不是**聚合的**(配了模型池 / 竞技场 / 预设驱动,每轮抽一个)。
    ///
    /// `nil` = 还不知道 —— 缓存行是加这个字段之前存的,或者网络还没回来,
    /// 又或者这条 BotPick 来自拿不到 bot config 的接口(邀请预览)。
    ///
    /// 判据跟服务端同一条:`bots.config.modelPool`(或历史键 `arena`)是个
    /// JSON 对象就算有池,见 edge 的 `modelPoolConfigFromBotConfig`。
    var hasModelPool: Bool? = nil

    /// 列表里该挂哪个模型标签 —— nil = 不挂。
    ///
    /// 只有**确定是单一模型**的 bot 才挂。聚合 bot 挂一个具体模型名是假的:
    /// 它每轮从池子里抽,而 `model_id` 只是抽不出来时的回落字段,把它当成
    /// 「这个 bot 用的模型」画出来会骗人(Todo #13/#14)。
    ///
    /// 不确定(`hasModelPool == nil`)也不挂 —— 宁可标签晚一拍出现,也不先
    /// 挂一个可能是假的上去再改口。这跟会话头部那一格是同一条规矩。
    var listModelSlug: String? {
        guard hasModelPool == false else { return nil }
        return model_id
    }
}
