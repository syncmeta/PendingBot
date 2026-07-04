#if os(macOS)
import Foundation

/// 一条 runner 健康异常：session 还「活着」（进程未退），但底层 agent 已经
/// 干不了活 —— 未登录 / 额度到顶。此前这两类故障只在 PTY 字节流里滚过、
/// app 零感知，用户得进终端肉眼看（分诊第 7 点）。
///
/// 检测面（能可靠拿到什么就报什么，不猜）：
/// - claude（PTY）：`SessionHealthScanner` 对终端输出做去 ANSI 的文案匹配，
///   匹配串全部从本机 claude CLI 2.1.201 二进制 strings 实测核出，非臆测。
/// - codex（app-server）：`account/chatgptAuthTokens/refresh` server-request
///   —— codex 要客户端刷新 ChatGPT token,我们无法提供 = 登录态失效的强信号。
struct CrewSessionHealth: Equatable {
    enum Kind: String, CaseIterable {
        /// 未登录 / 登录失效 / key 无效。
        case authRequired
        /// 额度到顶 / 余额不足。
        case usageLimit
    }
    let kind: Kind
    /// 人话说明 + 下一步动作（白板 fail-loud 消息与成员列表副行直接展示）。
    let detail: String
}

/// claude PTY 输出的健康扫描器：喂原始终端字节，产出**首次**命中的健康异常
/// （每 Kind 只报一次 —— 同一故障 TUI 会反复重绘,不能每帧都刷一条白板消息）。
///
/// 工作方式：
/// 1. 去 ANSI —— 小状态机剥掉 CSI / OSC / 两字节 ESC 序列与控制字符，只留
///    可见文本（UTF-8 多字节 ≥0x80 原样保留）。
/// 2. 滚动尾窗 —— 只保留最近一段明文（跨 chunk 断开的短语在窗内重新连上）。
/// 3. 匹配 —— 小写子串匹配下面的实测短语表。
///
/// 已知边界：终端里**内容级**出现这些短语（比如 agent 在 cat 一段含
/// "run /login" 的文档）会误报 —— 这是提示性 warning 且每 Kind 只一次，
/// 接受这个噪音换「不用进终端就知道挂了」（记 tech-debt）。
final class SessionHealthScanner {

    /// 实测短语表（本机 claude 2.1.201 strings 核出;小写匹配）。
    /// 注意保持短语足够特异 —— 别放 "usage limit" 这种会出现在普通 UI 提示里的宽串。
    static let authPhrases = [
        "run /login",             // "Please run /login to authenticate" 等全家
        "not logged in",          // "Not logged in. Run claude auth login …"
        "invalid api key",
    ]
    static let quotaPhrases = [
        "you've reached your",    // "You've reached your … usage limit"
        "you’ve reached your",    //  同上,弯引号变体
        "usage credit limit reached",
        "out of extra usage",     // "You're out of extra usage"
        "credit balance is too low",
        "credit balance too low",
    ]

    /// 尾窗上限（字符）。短语都 < 64 字符,4K 窗绰绰有余;超过 2 倍才截,
    /// 保证截断永远不会切在「刚到达还没匹配过」的短语中间。
    private let tailLimit = 4096

    private enum AnsiState { case normal, esc, skipOne, csi, osc, oscEsc }
    private var ansiState: AnsiState = .normal
    private var tail = ""
    private var fired: Set<CrewSessionHealth.Kind> = []

    /// 喂一段 PTY 原始字节，返回**新**命中的健康异常（通常空数组）。
    func feed(_ bytes: ArraySlice<UInt8>) -> [CrewSessionHealth] {
        guard fired.count < CrewSessionHealth.Kind.allCases.count else { return [] }
        var plain: [UInt8] = []
        for b in bytes {
            switch ansiState {
            case .normal:
                if b == 0x1b { ansiState = .esc }
                else if b >= 0x20, b != 0x7f { plain.append(b) }   // 含 UTF-8 ≥0x80
                else if b == 0x0a || b == 0x0d { plain.append(0x0a) }
            case .esc:
                switch b {
                case UInt8(ascii: "["): ansiState = .csi
                case UInt8(ascii: "]"): ansiState = .osc
                case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"),
                     UInt8(ascii: "+"), UInt8(ascii: "#"), UInt8(ascii: "%"):
                    ansiState = .skipOne                            // 两字节序列,再吃一个
                default: ansiState = .normal                        // ESC+单字节(如 ESC 7)
                }
            case .skipOne:
                ansiState = .normal
            case .csi:
                if (0x40...0x7e).contains(b) { ansiState = .normal }  // final byte
            case .osc:
                if b == 0x07 { ansiState = .normal }                  // BEL 终止
                else if b == 0x1b { ansiState = .oscEsc }
            case .oscEsc:
                ansiState = b == UInt8(ascii: "\\") ? .normal : .osc  // ST 终止
            }
        }
        guard !plain.isEmpty else { return [] }
        tail += String(decoding: plain, as: UTF8.self)
        if tail.count > tailLimit * 2 { tail = String(tail.suffix(tailLimit)) }

        let lower = tail.lowercased()
        var out: [CrewSessionHealth] = []
        if !fired.contains(.authRequired),
           Self.authPhrases.contains(where: { lower.contains($0) }) {
            fired.insert(.authRequired)
            out.append(CrewSessionHealth(
                kind: .authRequired,
                detail: "Claude Code 未登录或登录已失效 —— 打开这个 session 的终端跑 /login 登录后再继续。"))
        }
        if !fired.contains(.usageLimit),
           Self.quotaPhrases.contains(where: { lower.contains($0) }) {
            fired.insert(.usageLimit)
            out.append(CrewSessionHealth(
                kind: .usageLimit,
                detail: "Claude Code 额度受限（usage limit / 余额不足）—— 等额度窗口重置或检查订阅后再继续。"))
        }
        return out
    }
}
#endif
