import Foundation

/// One tool invocation captured from the SSE turn — `tool_call` creates it,
/// the matching `tool_result` fills in the result. Multiple tools per turn
/// stack into the trace shown above the bot's reply.
struct ToolTraceEvent: Identifiable, Hashable, Decodable {
    let id: UUID
    let name: String
    var input: String?
    var resultSummary: String?
    var resultError: String?
    var resultDetail: String?
    var done: Bool

    init(name: String, input: String?) {
        self.id = UUID()
        self.name = name
        self.input = input
        self.resultSummary = nil
        self.resultError = nil
        self.resultDetail = nil
        self.done = false
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case input
        case resultSummary = "result_summary"
        case resultError = "result_error"
        case resultDetail = "result_detail"
        case done
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.name = try c.decode(String.self, forKey: .name)
        self.input = try c.decodeIfPresent(String.self, forKey: .input)
        self.resultSummary = try c.decodeIfPresent(String.self, forKey: .resultSummary)
        self.resultError = try c.decodeIfPresent(String.self, forKey: .resultError)
        self.resultDetail = try c.decodeIfPresent(String.self, forKey: .resultDetail)
        self.done = (try? c.decode(Bool.self, forKey: .done)) ?? false
    }

    /// Per-tool human label. Mirrors the Envelope runner phrasing so the two
    /// surfaces (chat trace + envelope progress) read consistently.
    var headline: String {
        switch name {
        // search_web is the envelope-runner name; web_search the unified
        // server-side-search name; web_search_exa the Exa MCP name.
        case "search_web", "web_search", "web_search_exa": return "搜索"
        case "search_chat_history": return "搜会话"
        case "read_url", "web_fetch_exa": return "翻网页"
        case "execute_code":      return "跑代码"
        case "request_execute_code": return "请求跑代码"
        case "create_skill":      return "新增技能"
        case "query_user_memory": return "查记忆"
        case "read_attachment":   return "读附件"
        case "set_my_group_nickname": return "改群昵称"
        case "set_bot_group_description": return "改群简介"
        case "delegate_to_specialist": return "委托专家"
        default:                  return name
        }
    }

    var iconName: String {
        switch name {
        case "search_web", "web_search", "web_search_exa", "search_chat_history": return "magnifyingglass"
        case "read_url", "web_fetch_exa": return "safari"
        case "execute_code", "request_execute_code": return "terminal"
        case "create_skill": return "sparkles"
        case "query_user_memory": return "brain.head.profile"
        case "read_attachment": return "paperclip"
        case "delegate_to_specialist": return "person.2.wave.2"
        default: return "hammer"
        }
    }

    var inputLabel: String {
        switch name {
        case "search_web", "web_search", "web_search_exa": return "搜索词"
        case "search_chat_history": return "会话搜索词"
        case "read_url", "web_fetch_exa": return "网址"
        case "execute_code", "request_execute_code": return "代码"
        case "query_user_memory": return "记忆查询"
        case "create_skill": return "技能名"
        case "delegate_to_specialist": return "目标专家"
        default: return "输入"
        }
    }

    /// Sub-conversation id surfaced by `delegate_to_specialist` — extracted
    /// from `resultDetail` (which stashes it as "sub_conversation:<uuid>").
    /// Used by the trace row to deep-link into the child thread when a
    /// dedicated sub-conv view ships; nil for every other tool.
    var subConversationId: String? {
        guard name == "delegate_to_specialist",
              let detail = resultDetail,
              detail.hasPrefix("sub_conversation:") else { return nil }
        return String(detail.dropFirst("sub_conversation:".count))
    }

    var isCodeLike: Bool {
        name == "execute_code" || name == "request_execute_code"
    }

    var stateText: String {
        if !done { return "进行中" }
        return resultError == nil ? "完成" : "出错"
    }

    /// One-line preview shown next to the headline. For finished events we
    /// prefer the result; for in-flight ones we show the input.
    var preview: String? {
        if done {
            if let e = resultError { return "出错：\(e)" }
            if let s = resultSummary { return s }
        }
        return input
    }
}
