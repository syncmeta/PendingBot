import Foundation

/// PendingCrew 直接登录所需配置 —— 镜像 PendingBot HostedConfig 的 .remote 取值
/// (同一 Supabase 项目 + 同 Turnstile)。仅 P2 直接登录路径用;扫码/家族 SSO 不依赖。
enum CrewHostedConfig {
    static let supabaseURL = URL(string: "https://zafhoiwwpanpuashtnxy.supabase.co")!
    static let supabasePublishableKey = "sb_publishable_DobbxW0fIrpb21noFfMdXg_3xPrbm1d"
    static let turnstileSiteKey = "0x4AAAAAADLy8thL0jSFWJKF"
    static let turnstileHost = URL(string: "https://bot.pendingname.com")!
}
