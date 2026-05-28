#if os(macOS)
import Foundation

/// 解析本机 coding agent 的可执行路径。
///
/// 策略（按顺序）：
/// 1. 走 `/usr/bin/env <name>`（等价 `which <name>`，遵循用户登录 shell 的 PATH）
/// 2. fallback 探 Homebrew 常见路径（`/opt/homebrew/bin/`、`/usr/local/bin/`）
///
/// 找不到时返回 `nil`，**不抛** —— 调用方负责把"未安装"做成用户可见提示。
public enum LocalCodingAgentExecutable {

    /// 解析 `kind` 对应的可执行文件 URL。**Sync**：内部跑 `which`，几十毫秒级，
    /// 不值得搞 async API。
    public static func resolve(_ kind: LocalCodingAgentKind) -> URL? {
        if let url = whichLookup(name: kind.binaryName) {
            return url
        }
        for prefix in homebrewPrefixes {
            let candidate = URL(fileURLWithPath: prefix).appendingPathComponent(kind.binaryName)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Discovery 入口：返回所有当前机器上能找到的 kind。Phase 2 的 UI 用来填
    /// "Runner kind" 下拉。
    public static func discoverAvailable() -> [LocalCodingAgentKind] {
        LocalCodingAgentKind.allCases.filter { resolve($0) != nil }
    }

    // MARK: - internals

    private static let homebrewPrefixes: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
    ]

    /// 跑 `/usr/bin/env <name>`，从 stdout 解出可执行路径。
    ///
    /// 用 `env` 而不是直接读 `PATH` env var：
    /// - 我们在 PendingCrew 进程里看到的 PATH 是 GUI launchd 注入的（很短，
    ///   通常没有 user's shell rc 里的 PATH 扩展），跑 `env` 同样吃这个短 PATH。
    /// - 这不完美（用户的 zsh `.zshrc` 里 `export PATH=...` 的扩展不会被看到），
    ///   所以 fallback 才补 Homebrew 常见路径。
    private static func whichLookup(name: String) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // `which -- <name>` —— `--` 让 `which` 不把 leading-dash 名当 flag。
        // 不走 shell，所以 name 不需要 escape。
        process.arguments = ["which", "--", name]

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()  // 丢弃 stderr，避免污染
        // env 卫生：whichLookup 只是个工具发现调用，不带 user secret，
        // 但保持 minimal env 风格不传 PendingCrew 自己的进程 env。
        process.environment = [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
        ]

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8) ?? ""
        // `which` 可能返回多行；取第一行非空。
        let path = raw
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        guard !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }
}
#endif
