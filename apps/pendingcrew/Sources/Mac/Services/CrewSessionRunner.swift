#if os(macOS)
import Foundation
import SwiftUI

/// 一次 local coding agent 跑动的 view-side 视图模型。
///
/// P2 阶段是 stub —— 真正接通 `MacLocalCodingAgentService` 在 P4。
/// P2 commit 只需要这个类型存在，让 view 能编译。
@MainActor
final class CrewSessionRunner: ObservableObject {
    @Published private(set) var current: CrewSessionRun?

    init() {}
}

/// 单次 session 的 UI 视图模型。P2 stub —— 真实现 P4 接通。
@MainActor
final class CrewSessionRun: ObservableObject, Identifiable {
    enum Status: Equatable {
        case running, completed, cancelled, failed
    }

    let runID: UUID
    let crewId: String
    let kind: LocalCodingAgentKind
    let taskBrief: String

    @Published private(set) var status: Status = .running
    @Published private(set) var stdoutText: String = ""
    @Published private(set) var stderrText: String = ""
    @Published private(set) var exitCode: Int32?

    nonisolated var id: UUID { runID }

    init(runID: UUID, crewId: String, kind: LocalCodingAgentKind, taskBrief: String) {
        self.runID = runID
        self.crewId = crewId
        self.kind = kind
        self.taskBrief = taskBrief
    }

    func cancel() async {
        // P4 接 handle.cancel
    }
}
#endif
