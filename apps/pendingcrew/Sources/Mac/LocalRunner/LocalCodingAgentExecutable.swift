#if os(macOS)
import Foundation

/// 解析本机 coding agent 的可执行路径。
///
/// **关键约束**：从 Finder / Dock / Xcode 启动的 GUI app 拿到的是 launchd 注入的
/// 短 PATH（通常只有 `/usr/bin:/bin:/usr/sbin:/sbin`），**不含**用户在
/// `.zshrc` / `.zprofile` 里扩出来的 PATH —— 而 `claude` / `codex` 这类 CLI 常装在
/// `~/.local/bin`、npm / bun / cargo 等全局 bin 处。早期版本只查进程 PATH +
/// Homebrew 两条路径，于是装在 `~/.local/bin` 的 captain 在 GUI 里永远「找不到」
/// → 静默起不来。
///
/// 现在的策略（不依赖进程自身 PATH）：
/// 1. 起一次用户**登录 + 交互** shell（`$SHELL -lic`）把它解析好的 `$PATH` 抓回来
///    （`.zprofile` / `.zshrc` 里的 PATH 扩展两处都吃得到）。进程级缓存一次。
/// 2. 叠加一组常见安装目录兜底（`~/.local/bin`、Homebrew、各运行时全局 bin）。
/// 3. 在这些目录里找可执行文件，返回第一个命中。
///
/// 找不到时返回 `nil`，**不抛** —— 调用方负责把「未安装」做成用户可见提示。
public enum LocalCodingAgentExecutable {

    /// 解析 `kind` 对应的可执行文件 URL。命中目录列表里第一个可执行的同名文件。
    public static func resolve(_ kind: LocalCodingAgentKind) -> URL? {
        for dir in searchDirectories() {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(kind.binaryName)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Discovery 入口：返回所有当前机器上能找到的 kind。UI「Runner kind」下拉用。
    public static func discoverAvailable() -> [LocalCodingAgentKind] {
        LocalCodingAgentKind.allCases.filter { resolve($0) != nil }
    }

    // MARK: - internals

    /// 候选目录：登录 shell 的 PATH（缓存）+ 常见 CLI 安装位兜底。保序去重。
    private static func searchDirectories() -> [String] {
        var seen = Set<String>()
        var dirs: [String] = []
        func add(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            dirs.append(trimmed)
        }
        for d in cachedLoginShellPathDirs { add(d) }
        for d in fallbackPrefixes { add((d as NSString).expandingTildeInPath) }
        return dirs
    }

    /// 进程级缓存：登录 shell 的 PATH 解析一次即可。app 生命周期内 PATH 基本不变，
    /// 而起一次登录 shell 有 ~百毫秒开销（要 source rc 文件），不值得每次 `resolve`
    /// 都付（`discoverAvailable` 一轮就 N 次）。
    private static let cachedLoginShellPathDirs: [String] = loginShellPathDirs()

    /// 常见 CLI 安装目录 —— 登录 shell 抓不到时的兜底（用户级 bin、Homebrew、
    /// 各语言运行时全局 bin）。`~` 由调用处展开。
    private static let fallbackPrefixes: [String] = [
        "~/.local/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "~/.npm-global/bin",
        "~/.bun/bin",
        "~/.deno/bin",
        "~/.cargo/bin",
        "~/bin",
    ]

    /// 起一次用户登录+交互 shell，把它解析好的 `$PATH` 抓回来切成目录列表。
    /// 失败（无 SHELL / 起不来 / 解析不出）→ 空数组，靠 `fallbackPrefixes` 兜底。
    private static func loginShellPathDirs() -> [String] {
        guard let raw = loginShellPath() else { return [] }
        return raw.split(separator: ":").map(String.init)
    }

    /// 哨兵把真正的 `$PATH` 从交互式 rc 文件可能往 stdout 吐的噪声里摘出来。
    private static let sentinelOpen = "<<<PCREW_PATH:"
    private static let sentinelClose = ":PCREW_PATH>>>"

    private static func loginShellPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // `-l` 登录（source .zprofile / .profile）+ `-i` 交互（source .zshrc）——
        // PATH 扩展两处都可能在。`-c` 传命令后 shell 跑完即退，不会阻塞等 tty 输入。
        // 用哨兵包住 $PATH，再从 stdout 里摘 —— 交互式 rc 偶尔往 stdout 吐东西。
        // `printf` 用绝对路径，避免依赖刚要解析的那个 PATH。
        process.arguments = [
            "-lic",
            "/usr/bin/printf '\(sentinelOpen)%s\(sentinelClose)' \"$PATH\"",
        ]
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()  // 丢弃 rc 噪声
        // 不覆盖 environment：继承一个 sane 基底（TERM/USER/HOME 等），让登录 shell
        // 在其上按用户 rc 重建 PATH（rc 里的 `export PATH="$HOME/.local/bin:$PATH"`
        // 这种前置式扩展无论基底 PATH 长短都会把 ~/.local/bin 带进来）。

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        guard let lo = out.range(of: sentinelOpen)?.upperBound,
              let hi = out.range(of: sentinelClose, range: lo..<out.endIndex)?.lowerBound
        else { return nil }
        let path = String(out[lo..<hi])
        return path.isEmpty ? nil : path
    }
}
#endif
