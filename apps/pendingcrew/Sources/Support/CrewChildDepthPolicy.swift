import Foundation

/// 子 crew 深度 cap 的纯判定逻辑（`create_child_crew` 机长命令用）。
///
/// 拆成独立自包含文件（同 `MachineGrouping.swift` 的取舍）：`CrewStore`
/// 依赖 `AppModel`（未编进 PendingCrewTests bundle，拖进来会带上 Supabase /
/// GoogleSignIn 等一整条重依赖链），把纯逻辑摘出来才能被单测直接编译。
/// `CrewStore.shouldRejectChild` 是薄包装，调用方 API 不变。
enum CrewChildDepthPolicy {
    /// 根 crew depth 0，最长链 根→c1→c2→c3 = depth3。
    /// 父 depth `d` 挂一个子 → 子 depth = `d + 1`；超过 `cap` 则拒。
    static func shouldReject(depthOfParent d: Int, cap: Int = 3) -> Bool {
        d + 1 > cap
    }
}
