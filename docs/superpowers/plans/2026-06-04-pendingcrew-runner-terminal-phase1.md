# PendingCrew Runner Phase 1（本机终端闭环）— Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development（或 executing-plans）逐 task 实现。步骤用 `- [ ]`。

**Goal:** PendingCrew Mac 右栏 session 从"一次性子进程 + 结构化 transcript"改成**内嵌真终端跑交互式 `claude`/`codex`（自动审批）**——读=终端原样显示，控=键盘 + 程序化字节注入。

**Architecture:** 加 SwiftTerm（SPM），`AgentTerminalSession` 持 `LocalProcessTerminalView` 按 kind 起交互式 CLI + 控制 API；`AgentTerminalView`（NSViewRepresentable）宿主进右栏；`CrewSessionRunner`/`CrewSessionWindowView` 改用之；退役一次性路径（`LocalCodingAgentProcess`/`RunnerEventParser`/`SteeringChannel`/`InteractionChannel`）；`SessionProxy` 推送降级为粗粒度生命周期（跨端控保留，跨端看内容降级=Phase 2 隧道补）。

**Tech Stack:** SwiftUI macOS、SwiftTerm v1.13、XcodeGen。

**已核实事实（权威）：**
- SwiftTerm v1.13 `LocalProcessTerminalView`：`startProcess(executable:String, args:[String], environment:[String]?, execName:String?, currentDirectory:String?)`；`processDelegate: LocalProcessTerminalViewDelegate?`（`processTerminated(source:exitCode:)`）；`terminate()`。`environment` 是 `["KEY=VALUE", …]`。向子进程注入字节的入口=继承自 `LocalProcessDelegate`/`TerminalViewDelegate` 的 `send(source:data:)`（**实施时读 SPM 里 resolve 的真实源确认注入法**——可能是直接调 `feed`/底层 `LocalProcess.send`；以包源为准）。
- CLI flag（本机实测）：claude 2.1.156 自动审批 `--dangerously-skip-permissions`、resume `-r <id>`；codex 0.133.0 自动审批 `-a never --sandbox workspace-write`（或 `--dangerously-bypass-approvals-and-sandbox`）、resume `codex resume`。
- 现状：`CrewSessionRunner.swift`(693 行) `CrewSessionRun` 持 `LocalCodingAgentRunHandle`，`observe()` 把 stdout 行喂 `RunnerEventParser.parse` → `events:[RunnerEvent]`，并 `publishToServer`/`SessionState.from(events:)` 给 T4.5。`CrewSessionWindowView.swift` 渲染 `events`。

**通用验证：** `cd apps/pendingcrew && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' -derivedDataPath /tmp/pendingcrew-dd build 2>&1 | tail -8` → `** BUILD SUCCEEDED **`。**加文件/改 project.yml 后必须 `cd apps/pendingcrew && xcodegen` 重生 pbxproj 再 build（否则文件不进 target、假绿）。**

---

## Task 1: 接入 SwiftTerm（SPM）+ 确认 API

**Files:** `apps/pendingcrew/project.yml`

- [ ] **Step 1: 在 project.yml 加 SPM 依赖**

顶层加 `packages`，target `PendingCrew` 加 `dependencies`：

```yaml
packages:
  SwiftTerm:
    url: https://github.com/migueldeicaza/SwiftTerm
    from: 1.13.0
targets:
  PendingCrew:
    # ...existing...
    dependencies:
      - package: SwiftTerm
```

（保留现有 target 配置，只新增 `packages:` 顶层块 + target 下 `dependencies:`。）

- [ ] **Step 2: 重生工程 + 解析依赖 + 构建**

```bash
cd /Users/hey/Untitled/Pendingname/PendingBot/dev/.claude/worktrees/elastic-shannon-e83496/apps/pendingcrew
xcodegen
xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' -derivedDataPath /tmp/pendingcrew-dd -resolvePackageDependencies 2>&1 | tail -5
xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' -derivedDataPath /tmp/pendingcrew-dd build 2>&1 | tail -8
```
Expected: 依赖 resolve 到 SwiftTerm 1.13.x；`** BUILD SUCCEEDED **`（此时还没用它，只验证接入）。

- [ ] **Step 3: 读真实 API 确认注入法**

在 resolve 后的包里读 `LocalProcessTerminalView` 源（`/tmp/pendingcrew-dd/SourcePackages/checkouts/SwiftTerm/Sources/SwiftTerm/Mac/MacLocalTerminalView.swift`），**确认**：`startProcess` 签名、向子进程**程序化注入字节**的确切方法、`processDelegate`/`processTerminated`。把确认结果写进本任务 commit body（供 Task 2 用）。

- [ ] **Step 4: Commit**

```bash
git add apps/pendingcrew/project.yml apps/pendingcrew/PendingCrew.xcodeproj/project.pbxproj
git commit -m "build(pendingcrew): 接入 SwiftTerm SPM 依赖(v1.13)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 2: `AgentTerminalSession`

**Files:** Create `apps/pendingcrew/Sources/Mac/LocalRunner/AgentTerminalSession.swift`

- [ ] **Step 1: 创建文件**（注入法以 Task 1 Step 3 确认的为准；下面用 `send(source:data:)`，若实际不同照实改）

```swift
#if os(macOS)
import Foundation
import SwiftTerm

/// 一个内嵌真终端的 coding-agent 会话：在 PTY 里跑交互式 claude/codex(自动审批)，
/// 读=终端原样显示，控=键盘(SwiftTerm 原生) + 程序化 send()/interrupt() 字节注入。
@MainActor
final class AgentTerminalSession: ObservableObject {
    enum Status: Equatable { case running, exited(Int32?) }

    let kind: LocalCodingAgentKind
    let terminalView: LocalProcessTerminalView
    @Published private(set) var status: Status = .running

    private final class Delegate: NSObject, LocalProcessTerminalViewDelegate {
        var onExit: ((Int32?) -> Void)?
        func processTerminated(source: TerminalView, exitCode: Int32?) { onExit?(exitCode) }
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }
    private let delegate = Delegate()

    /// `executable` = 已 resolve 的 claude/codex 绝对路径；`workdir` = 工作目录。
    init(kind: LocalCodingAgentKind, executable: String, workdir: String,
         model: String? = nil, resumeSessionId: String? = nil, env: [String: String]) {
        self.kind = kind
        self.terminalView = LocalProcessTerminalView(frame: .zero)
        self.terminalView.processDelegate = delegate
        delegate.onExit = { [weak self] code in
            Task { @MainActor in self?.status = .exited(code) }
        }
        var envArr = env.map { "\($0.key)=\($0.value)" }
        if !envArr.contains(where: { $0.hasPrefix("TERM=") }) { envArr.append("TERM=xterm-256color") }
        terminalView.startProcess(
            executable: executable,
            args: Self.argv(kind: kind, model: model, resumeSessionId: resumeSessionId),
            environment: envArr,
            currentDirectory: workdir
        )
    }

    /// 交互式 + 自动审批 argv（flag 本机实测，2026-06-04）。
    static func argv(kind: LocalCodingAgentKind, model: String?, resumeSessionId: String?) -> [String] {
        switch kind {
        case .claudeCode:
            var a: [String] = []
            if let id = resumeSessionId { a += ["--resume", id] }
            a += ["--dangerously-skip-permissions"]
            if let m = model { a += ["--model", m] }
            return a
        case .codex:
            if let id = resumeSessionId { return ["resume", id, "-a", "never", "--sandbox", "workspace-write"] }
            var a = ["-a", "never", "--sandbox", "workspace-write"]
            if let m = model { a += ["--model", m] }
            return a
        }
    }

    /// 程序化发文本（prompt / steer）：写文本 + 回车。供 captain 编排 / 远端 / 手动注入。
    func send(_ text: String) {
        feed(Array((text + "\r").utf8))
    }
    /// 打断进行中的回合(Esc)。
    func interrupt() { feed([0x1b]) }
    /// 终止子进程。
    func stop() { terminalView.terminate() }

    private func feed(_ bytes: [UInt8]) {
        // 注入入口以 Task 1 确认为准；send(source:data:) 是 TerminalViewDelegate 把
        // 用户按键转发给子进程的同一通道，程序化复用它即可。
        terminalView.send(source: terminalView, data: bytes[...])
    }
}
#endif
```

- [ ] **Step 2: 构建**（新文件 → 先 `xcodegen` 再 build）

```bash
cd /Users/hey/Untitled/Pendingname/PendingBot/dev/.claude/worktrees/elastic-shannon-e83496/apps/pendingcrew && xcodegen
xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' -derivedDataPath /tmp/pendingcrew-dd build 2>&1 | tail -8
```
Expected `** BUILD SUCCEEDED **`。若 `send`/delegate 签名与真实 API 不符 → 按 Task 1 Step 3 的真实签名改 `feed`/Delegate。

- [ ] **Step 3: Commit**

```bash
git add apps/pendingcrew/Sources/Mac/LocalRunner/AgentTerminalSession.swift apps/pendingcrew/PendingCrew.xcodeproj/project.pbxproj
git commit -m "feat(pendingcrew): AgentTerminalSession(PTY 内嵌交互式 CLI + 字节注入控制)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 3: `AgentTerminalView`（SwiftUI 宿主）

**Files:** Create `apps/pendingcrew/Sources/Mac/Views/AgentTerminalView.swift`

- [ ] **Step 1: 创建文件**

```swift
#if os(macOS)
import SwiftUI
import SwiftTerm

/// 把 AgentTerminalSession 的 LocalProcessTerminalView 宿主进 SwiftUI。
struct AgentTerminalView: NSViewRepresentable {
    let session: AgentTerminalSession
    func makeNSView(context: Context) -> LocalProcessTerminalView { session.terminalView }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
#endif
```

- [ ] **Step 2: 构建**（`xcodegen` 再 build）→ `** BUILD SUCCEEDED **`
- [ ] **Step 3: Commit**

```bash
git add apps/pendingcrew/Sources/Mac/Views/AgentTerminalView.swift apps/pendingcrew/PendingCrew.xcodeproj/project.pbxproj
git commit -m "feat(pendingcrew): AgentTerminalView(NSViewRepresentable 宿主终端)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 4: 改 `CrewSessionRunner` 用 AgentTerminalSession（集成，重）

**Files:** Modify `apps/pendingcrew/Sources/Mac/Services/CrewSessionRunner.swift`

> 这是最重的一步。先**完整读** `CrewSessionRunner.swift`，再按下述意图改，保 `CrewSessionRun` 的对外接口（被 `CrewSessionWindowView` / `MacRootView` 用）尽量不破坏。

- [ ] **Step 1: 让 `CrewSessionRun` 持 `AgentTerminalSession`**
  - `CrewSessionRunner.start(...)`：仍 `resolveExecutable(kind)`；不再 `service.runSession`→`LocalCodingAgentRunHandle`，改成 `AgentTerminalSession(kind:executable:workdir:model:env:)`（env 复用现有白名单来源）。
  - `CrewSessionRun`：去掉 `currentHandle`/`observe(handle)`/`stdoutText`/`events:[RunnerEvent]`/`RunnerEventParser.parse` 那套；改持 `let terminalSession: AgentTerminalSession`，`status` 跟随 `terminalSession.$status`（running/exited）。
  - **远端控制保留**：原 `lastRemoteCommand` / `session.command` 处理（send_prompt/steer/cancel）改映射到 `terminalSession.send(...)` / `interrupt()` / `stop()`。
- [ ] **Step 2: SessionProxy 推送降级为粗粒度**
  - `publishToServer` / `SessionState.from(...)`：不再逐 `RunnerEvent`；改只在 started / exited 时发粗粒度生命周期（用现有 `CrewSessionServerLink.publish` 接口，`RunnerEvent` 退化成 `.started` / `.finished` 两种即可，或加一个轻量 lifecycle 值）。**保留 SessionProxy 连接**（Phase 2 改载终端字节）。
- [ ] **Step 3: 构建**（`xcodegen` 若无新文件可跳；CrewSessionRunner 是改不是加，直接 build）

```bash
cd /Users/hey/Untitled/Pendingname/PendingBot/dev/.claude/worktrees/elastic-shannon-e83496/apps/pendingcrew
xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' -derivedDataPath /tmp/pendingcrew-dd build 2>&1 | tail -12
```
Expected `** BUILD SUCCEEDED **`（此步会因 `CrewSessionWindowView` 仍引用旧 `events` 而可能报错——Task 5 一起收口；若编译卡在 window view，先把 window view 的 events 引用注释/占位让 runner 编过，Task 5 正式改）。

- [ ] **Step 4: Commit**

```bash
git add apps/pendingcrew/Sources/Mac/Services/CrewSessionRunner.swift
git commit -m "refactor(pendingcrew): CrewSessionRun 改持 AgentTerminalSession + SessionProxy 降级粗粒度

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 5: `CrewSessionWindowView` 换成终端

**Files:** Modify `apps/pendingcrew/Sources/Mac/Views/CrewSessionWindowView.swift`

- [ ] **Step 1:** 先**完整读**该文件。把渲染 `events:[RunnerEvent]` 的结构化 transcript 区域换成 `AgentTerminalView(session: run.terminalSession)`（铺满）。保留窗口的标题/状态条/关闭等外壳；底部可留一个文本框调 `run.terminalSession.send(text)` 做手动注入（可选，省了也行——终端能直接打字）。
- [ ] **Step 2: 构建** → `** BUILD SUCCEEDED **`（此时 runner + window 都不再引用旧 events，应整体编过）
- [ ] **Step 3: Commit**

```bash
git add apps/pendingcrew/Sources/Mac/Views/CrewSessionWindowView.swift
git commit -m "feat(pendingcrew): 右栏 session 窗口换成内嵌终端(AgentTerminalView)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 6: 退役一次性路径

**Files:** Delete `LocalCodingAgentProcess.swift` / `RunnerEventParser.swift` / `SteeringChannel.swift` / `InteractionChannel.swift`；Modify `LocalCodingAgentSpec.swift`（去 `--print`/`exec --json` argv 分支，保 kind/cwd/env）；Modify `LocalCodingAgentService.swift`（若 `runSession`/`LocalCodingAgentRunHandle` 已无人用则一并精简/删）；Modify Tests。

- [ ] **Step 1: 确认无他用再删**

```bash
cd /Users/hey/Untitled/Pendingname/PendingBot/dev/.claude/worktrees/elastic-shannon-e83496
grep -rn "LocalCodingAgentProcess\|RunnerEventParser\|SteeringChannel\|InteractionChannel\|runSession\|LocalCodingAgentRunHandle" apps/pendingcrew/Sources
```
对每个待删类型确认引用只剩自身/测试。`InteractionChannel`(ask_human MCP)删前再 `grep -rn "ask_human\|InteractionChannel" apps/pendingcrew apps/edge` 确认仅本地 runner 路径用。

- [ ] **Step 2: 删文件 + 改 spec/service + 删/改对应测试**
  - 删 4 个文件；`LocalCodingAgentSpec` 去一次性 argv；测试里 `RunnerEventParserTests.swift` / `LocalCodingAgentTests.swift` 中针对已删逻辑的用例删掉（保留仍有效的）。
- [ ] **Step 3: `xcodegen`（文件增删要重生）+ 构建 + 测试**

```bash
cd /Users/hey/Untitled/Pendingname/PendingBot/dev/.claude/worktrees/elastic-shannon-e83496/apps/pendingcrew && xcodegen
xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' -derivedDataPath /tmp/pendingcrew-dd build 2>&1 | tail -8
xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrewTests -destination 'platform=macOS' -derivedDataPath /tmp/pendingcrew-dd test 2>&1 | tail -15
```
Expected：build SUCCEEDED；测试通过（或只剩有效用例）。

- [ ] **Step 4: Commit**

```bash
git add -A apps/pendingcrew
git commit -m "chore(pendingcrew): 退役一次性 runner 路径(Process/Parser/Steering/Interaction)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Task 7: 验证 + 账本

- [ ] **Step 1: 干净构建真绿**（清 derivedData 防假绿）

```bash
cd /Users/hey/Untitled/Pendingname/PendingBot/dev/.claude/worktrees/elastic-shannon-e83496/apps/pendingcrew
rm -rf /tmp/pcrew-verify
xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' -derivedDataPath /tmp/pcrew-verify clean build 2>&1 | grep -E "Compiling.*AgentTerminal|error:|BUILD SUCCEEDED|BUILD FAILED"
```

- [ ] **Step 2: 真跑（需用户登录态 + 本机 CLI）**
  - `open` 起 app，右栏新建一个 claude session：终端显示 claude TUI、能打字交互、`send()` 程序化发一条 prompt 跑通、interrupt 能断、stop 能终止；codex 同验一遍。截图给用户确认。
- [ ] **Step 3: 账本**
  - `docs/progress.md` 顶部加 Phase 1 rollup；`docs/tech-debt.md` 记：跨端看内容降级（待 Phase 2 终端隧道）+ 自动审批放权 + CLI flag 漂移 fail-loud。
  - Commit。

---

## Self-Review
- Spec §2 终端会话 → Task 2；§3 UI → Task 3/5；§4 退役+降级 → Task 4/6；§5 Phase 划分(本期只本机) → 贯穿；§7 验证 → Task 7。
- 风险点已标：SwiftTerm 注入法以包源为准(Task 1/2)、CrewSessionRunner 重构保接口(Task 4)、删前 grep 确认(Task 6)、假绿用 xcodegen+clean build 防(全程)。
