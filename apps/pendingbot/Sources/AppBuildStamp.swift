import Foundation

/// 读构建戳 —— 「手上这个包是从哪份代码打出来的」。
///
/// 值由 `scripts/release/stamp-build-info.sh` 在构建末尾写进产物 Info.plist
/// （见 `project.yml` 的 postBuildScripts），iOS / macOS 两端都打。
///
/// 三种状态必须能分开，所以这里不做「反正都当没有」的合并处理：
///   - **有 sha**      → 正常构建，`abc1234`；工作区脏的话后面跟 `-dirty`
///   - **`unknown`**   → 打戳跑了，但那台机器上没有 git 信息（tarball / 浅克隆 /
///                       没装 git）。**这是诚实的答案，不是错误** —— 外部人从
///                       源码 zip 编出来的包就长这样。
///   - **键不存在**    → 打戳这一步压根没跑（build phase 被删了之类），是工程
///                       配置坏了。跟上面那种不是一回事，所以措辞也不同。
///
/// 任何情况下都不编一个占位 sha 假装能比对 —— 那正是这套东西要防的事。
enum AppBuildStamp {
    /// 从一份 Info.plist 字典里拼出「版本 (build) · 戳」。做成吃参数的纯函数是
    /// 为了能直接测，不必真起一个 app。
    static func versionDisplay(info: [String: Any]) -> String {
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build)) · \(stampDisplay(info: info))"
    }

    static func stampDisplay(info: [String: Any]) -> String {
        guard let commit = info["BuildStampCommit"] as? String, !commit.isEmpty else {
            return "无版本戳"
        }
        guard commit != "unknown" else { return "版本戳未知" }
        guard commit.count >= 7 else { return "版本戳异常" }
        let dirty = (info["BuildStampDirty"] as? Bool) ?? false
        return dirty ? "\(commit.prefix(7))-dirty" : String(commit.prefix(7))
    }

    static var current: String {
        versionDisplay(info: Bundle.main.infoDictionary ?? [:])
    }
}
