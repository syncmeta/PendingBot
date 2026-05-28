import Foundation

/// PendingCrew 认证凭据。
///
/// 两条路径（spec v2 §5）：
/// - `deviceGrant`：登录态，扫码后从 PendingBot Edge 拿到的 device grant token。
///   token 前缀 `pdg_`。走 unified billing → subject 钱包。
/// - `byok`：未登录态，用户自己填的 LLM provider key（Anthropic / OpenAI / Gemini）。
///   只用于本地 crew，不能用 Fly。Phase 5 实装。
struct PendingCrewAuthCredential: Equatable {
    enum Kind: Equatable {
        case deviceGrant
        case byok
    }

    let kind: Kind
    let token: String

    static func resolveDeviceGrant(_ token: String?) -> PendingCrewAuthCredential? {
        guard let token = clean(token), token.hasPrefix("pdg_") else { return nil }
        return PendingCrewAuthCredential(kind: .deviceGrant, token: token)
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}
