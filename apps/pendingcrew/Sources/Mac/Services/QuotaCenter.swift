#if os(macOS)
import Foundation

/// 订阅额度中心（#455）：聚合 claude / codex 两家的「已用百分比 + 重置时刻」，
/// 供 ① 侧栏额度显示 ② session 的 `get_quota` 工具（经 quota.json 快照文件）。
///
/// 数据源（2026-07-05 实测定档，见 handbook session-quota 页）：
/// - **claude**：`claude -p "/usage"` —— CLI 的本地 control-request（实测不烧额度、
///   自己处理 OAuth refresh，免 Keychain 工程尾巴），文本经 `ClaudeUsageTextParser`。
/// - **codex**：`~/.codex/sessions/**/rollout-*.jsonl` 最新文件的 `token_count.
///   rate_limits`（每轮落盘,无进程也能读），经 `CodexRolloutQuotaParser`。
///   app-server 的 `account/rateLimits/read` 更实时,留给后续增量。
///
/// 两家都**没有剩余 token 绝对值**，只有百分比+重置——UI/工具照实呈现，不编造。
@MainActor
final class QuotaCenter: ObservableObject {
    static let shared = QuotaCenter()

    @Published private(set) var claude: AgentQuotaSnapshot?
    @Published private(set) var codex: AgentQuotaSnapshot?
    @Published private(set) var refreshing = false

    /// helper（离线子进程）读的快照文件；与白板/控制通道同目录（--dir）。
    static let quotaFileName = "quota.json"

    private var timer: Timer?
    private let directory: URL
    private let codexSessionsDir: URL

    init(directory: URL? = nil, codexSessionsDir: URL? = nil) {
        self.directory = directory ?? LocalWhiteboardStore.defaultDirectory
        self.codexSessionsDir = codexSessionsDir
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    /// 启动：立即刷一次，然后 10 分钟一轮。/usage 是本地 control-request 不烧额度，
    /// 但一次要跑几秒的子进程 —— 别高频轰。
    func start() {
        guard timer == nil else { return }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// 刷一轮两家额度（各自 best-effort：一家失败不影响另一家，保留旧值）。
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        async let c = Self.fetchClaude()
        async let x = Self.fetchCodex(sessionsDir: codexSessionsDir)
        if let snap = await c { claude = snap }
        if let snap = await x { codex = snap }
        persistSnapshotFile()
    }

    /// 落快照文件给 helper 的 get_quota 读（原子写；与控制通道同目录）。
    private func persistSnapshotFile() {
        let file = AgentQuotaFile(claude: claude, codex: codex)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: directory.appendingPathComponent(Self.quotaFileName), options: .atomic)
    }

    // MARK: - fetchers（nonisolated，跑在后台）

    /// `claude -p "/usage"`：resolve 不到 claude / 超时 / 输出解析不出 → nil。
    nonisolated private static func fetchClaude() async -> AgentQuotaSnapshot? {
        guard let exe = LocalCodingAgentExecutable.resolve(.claudeCode) else { return nil }
        let text: String? = await Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe.path)
            p.arguments = ["-p", "/usage"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            do { try p.run() } catch { return nil }
            // 兜底超时：/usage 实测几秒返回;卡住(如首次 OAuth refresh 挂起)则杀掉,
            // 这轮放弃,别把 QuotaCenter 挂死。
            let deadline = Date().addingTimeInterval(30)
            while p.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.2)
            }
            if p.isRunning { p.terminate(); return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        }.value
        guard let text else { return nil }
        return ClaudeUsageTextParser.parse(text)
    }

    /// 最新 rollout jsonl 的 rate_limits。目录不存在（没装/没用过 codex）→ nil。
    nonisolated private static func fetchCodex(sessionsDir: URL) async -> AgentQuotaSnapshot? {
        await Task.detached(priority: .utility) {
            guard let newest = newestRolloutFile(under: sessionsDir),
                  let data = try? Data(contentsOf: newest) else { return nil }
            // rollout 可能很大：只解析尾部 256KB（rate_limits 每轮都写,尾部必有最新）。
            let tail = data.count > 262_144 ? data.suffix(262_144) : data[...]
            guard let text = String(data: Data(tail), encoding: .utf8) else { return nil }
            return CodexRolloutQuotaParser.parse(text)
        }.value
    }

    /// `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` 里 mtime 最新的一个。
    nonisolated private static func newestRolloutFile(under dir: URL) -> URL? {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                    options: [.skipsHiddenFiles]) else { return nil }
        var newest: (URL, Date)? = nil
        for case let url as URL in e where url.lastPathComponent.hasPrefix("rollout-")
            && url.pathExtension == "jsonl" {
            let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if newest == nil || m > newest!.1 { newest = (url, m) }
        }
        return newest?.0
    }
}
#endif
