#if os(macOS)
import Foundation

/// 解析 session 的工作目录（spec §8 / §11 worktree 隔离）。
/// `isolation=on` 且 crew 目录是 git repo → 在当前分支上开一个独立 worktree（新分支）；
/// 否则（off / 非 git repo / 拿不到分支 / add 失败）→ 用 crew 共享目录（fail-soft）。
enum SessionWorkspace {
    static func resolve(crewDirectory: URL, isolation: Bool, hint: String) -> URL {
        guard isolation else { return crewDirectory }
        guard (try? GitWorktreeService.isGitRepository(at: crewDirectory)) == true else {
            print("[session-workspace] isolation 要求但 \(crewDirectory.path) 非 git repo → 退回共享目录")
            return crewDirectory
        }
        guard let baseBranch = (try? GitWorktreeService.currentBranch(at: crewDirectory)) ?? nil else {
            print("[session-workspace] 拿不到当前分支（detached?）→ 退回共享目录")
            return crewDirectory
        }
        let suffix = UUID().uuidString.lowercased().prefix(6)
        let newBranch = "pendingcrew/session-\(suffix)"
        do {
            return try GitWorktreeService.addWorktree(
                sourceRepository: crewDirectory,
                branchName: baseBranch,
                newBranchName: newBranch,
                worktreeNameHint: hint.isEmpty ? "session" : hint
            )
        } catch {
            print("[session-workspace] worktree add 失败（\(error)）→ 退回共享目录")
            return crewDirectory
        }
    }
}
#endif
