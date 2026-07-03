# Captain 自主新建 session / 子 crew 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给本地模式的机长(captain)两个 MCP 工具 `start_session` 与 `create_child_crew`,让它无需人类逐次确认就能在当前 crew 里起 worker session、或以当前 crew 为父建子 crew(子 crew 自动起自己的机长)。

**Architecture:** 照搬既有 `rename_crew` 的**离线文件控制通道**模式。机长的 MCP helper 是碰不到 app 进程、不联网的离线子进程,只能读写 `--dir` 下共享文件。新工具把请求写成命令文件 → app 侧 `CrewStore` 靠目录监听(`LocalWhiteboardStore.directoryChanged`)排空 → 执行(起 session 走已合并的 `CrewSessionRunner.startForBrief`;建子 crew 走 `LocalCrewStore.createCrew` + `attachParent` + `captainAutostartRequest`)。`rename_crew` 是 last-write-wins 单文件;起 session/建子 crew 可重复,所以用**每命令一文件的队列**。

**Tech Stack:** Swift 5 / SwiftUI / Foundation(离线 store 自包含,编进 `pendingcrew-mcp` re-exec helper + `PendingCrewTests` bundle);XCTest;xcodegen + xcodebuild(macOS)。

## Global Constraints

- **范围 = 本地模式(BYOK/local)**。edge/登录态路径(`create_child_crew_inheriting_responsibility` RPC + bot 鉴权 + relay 同步)是 non-goal,本计划不碰。本地只记**结构父边**(DAG 展示),不做 responsibility 分摊继承。
- **两个工具仅机长可见可调**:在 `tools/list` 的 `isCaptain` 分支注册,`tools/call` 再加 `isCaptain` 守卫(与 `answer_decision`/`rename_crew` 完全一致)。
- **全自主**:机长判断后直接执行,不走人类确认。护栏 = 可见(立即出现在侧栏+群聊)+ 可停(既有停 session/停机长入口)+ 子 crew 深度上限。
- **子 crew 深度 cap = 3**(硬编码;根 crew depth 0,最长链 `根→c1→c2→c3`)。执行 `create_child_crew` 前算当前 crew 深度 `d`,`d + 1 > 3` 即拒。配合 `attachParent` 既有禁环。
- **离线 store 只用 Foundation**,`@unchecked Sendable`,app↔helper 并发沿用既有 last-write-wins/各文件独立的低频可接受 tech-debt。
- **命令文件后缀** `.crewcmd.json`,与 `.crewmeta.json`(rename)/`.json`(白板)/`.approvals.json` 不冲突,共用 `LocalWhiteboardStore.defaultDirectory`。
- **真机活验记为尾巴**(并入既有 captain 真机 QA 批次 task #443 / `20260626-qa`):真起 claude/codex worker、真建子 crew 看子机长自动报到。本计划的验收门是 swiftc 单测 + `xcodebuild` macOS build 绿。
- **commit 规范**:小单元 auto-commit,co-author `Co-Authored-By: Claude <noreply@anthropic.com>`,不带模型名。

## File Structure

| 文件 | 责任 | 动作 |
|---|---|---|
| `apps/pendingcrew/Sources/Stores/LocalCrewControlStore.swift` | 离线控制通道。既有 rename(单文件)+ **新增命令队列** | Modify |
| `apps/pendingcrew/Tests/PendingCrewTests/LocalCrewControlStoreTests.swift` | 控制通道单测(纯 Foundation,已证可跑) | Modify |
| `apps/pendingcrew/Sources/Stores/LocalCrewStore.swift` | 本地 crew 真源 + DAG。**新增 `depth(of:)`** | Modify |
| `apps/pendingcrew/Tests/PendingCrewTests/LocalCrewStoreDepthTests.swift` | 深度 helper 单测 | Create |
| `apps/pendingcrew/Sources/Mcp/McpServer.swift` | MCP 工具注册 + 分发。**新增两工具** | Modify |
| `apps/pendingcrew/Tests/PendingCrewTests/McpServerCaptainSpawnTests.swift` | 两工具入队 + isCaptain 守卫单测 | Create |
| `apps/pendingcrew/Sources/Stores/CrewStore.swift` | app 侧排空落地。**新增 `drainCommands` + `sessionSpawnRequest` + `create_child_crew` 执行** | Modify |
| `apps/pendingcrew/Sources/Mac/Services/CrewSessionRunner.swift` | worker 启动例程。**`startForBrief` 扩 runnerOverride + isolation** | Modify |
| `apps/pendingcrew/Sources/Mac/Views/MacRootView.swift` | 观察 store 请求驱动 runner。**新增观察 `sessionSpawnRequest`** | Modify |
| `apps/pendingcrew/Resources/Prompts/crew-captain.zh.md` | 机长世界观 prompt。**补 create_child_crew + start_session isolation** | Modify |
| `docs/tech-debt.md` | 清 tech-debt:61(start_session 漂移) | Modify |

**说明**:`start_session` 需要 `CrewSessionRunner`(app UI 层持有,`CrewStore` 不直接持有)。沿用既有 `captainAutostartRequest` 模式——`CrewStore` 只 `@Published` 一个请求,`MacRootView` 观察后调 runner。`create_child_crew` 无需 runner(建 crew + 自动起机长走既有 `captainAutostartRequest` → `MacRootView` → `runner.startCaptain`),`CrewStore` 内即可闭环。

---

### Task 1: 控制通道加命令队列(`CrewCommand` + enqueue + drain)

**Files:**
- Modify: `apps/pendingcrew/Sources/Stores/LocalCrewControlStore.swift`
- Test: `apps/pendingcrew/Tests/PendingCrewTests/LocalCrewControlStoreTests.swift`

**Interfaces:**
- Produces:
  - `struct CrewCommand: Codable, Equatable { let id: String; let crewId: String; let kind: String; let brief: String; let runner: String?; let isolation: Bool?; let title: String?; let ts: String }`(`kind` ∈ `"start_session"` | `"create_child_crew"`)
  - `LocalCrewControlStore.enqueueStartSession(crewId: String, brief: String, runner: String?, isolation: Bool?)`
  - `LocalCrewControlStore.enqueueCreateChildCrew(crewId: String, brief: String, title: String?)`
  - `LocalCrewControlStore.drainCommands() -> [CrewCommand]`(读全部 `.crewcmd.json`、删文件、返回)

- [ ] **Step 1: 写失败测试** — 追加到 `LocalCrewControlStoreTests.swift`:

```swift
func testEnqueueStartSessionThenDrain() {
    let s = LocalCrewControlStore(directory: tempDir())
    s.enqueueStartSession(crewId: "local-a", brief: "修登录", runner: "claude", isolation: true)
    let cmds = s.drainCommands()
    XCTAssertEqual(cmds.count, 1)
    XCTAssertEqual(cmds[0].kind, "start_session")
    XCTAssertEqual(cmds[0].crewId, "local-a")
    XCTAssertEqual(cmds[0].brief, "修登录")
    XCTAssertEqual(cmds[0].runner, "claude")
    XCTAssertEqual(cmds[0].isolation, true)
    // 排空后再 drain 为空(文件已删)
    XCTAssertTrue(s.drainCommands().isEmpty)
}

func testEnqueueMultipleCommandsAllDrained() {
    let s = LocalCrewControlStore(directory: tempDir())
    s.enqueueStartSession(crewId: "c", brief: "活一", runner: nil, isolation: nil)
    s.enqueueStartSession(crewId: "c", brief: "活二", runner: "codex", isolation: false)
    s.enqueueCreateChildCrew(crewId: "c", brief: "拆一块", title: "支付")
    let cmds = s.drainCommands()
    XCTAssertEqual(cmds.count, 3)
    XCTAssertEqual(cmds.filter { $0.kind == "start_session" }.count, 2)
    XCTAssertEqual(cmds.filter { $0.kind == "create_child_crew" }.count, 1)
    XCTAssertEqual(cmds.first { $0.kind == "create_child_crew" }?.title, "支付")
}

func testEnqueueRejectsEmptyBrief() {
    let s = LocalCrewControlStore(directory: tempDir())
    s.enqueueStartSession(crewId: "c", brief: "   \n ", runner: nil, isolation: nil)
    s.enqueueCreateChildCrew(crewId: "c", brief: "", title: nil)
    XCTAssertTrue(s.drainCommands().isEmpty)
}

func testCommandsAndRenamesDoNotInterfere() {
    let s = LocalCrewControlStore(directory: tempDir())
    s.requestRename(crewId: "c", name: "起个名")
    s.enqueueStartSession(crewId: "c", brief: "干活", runner: nil, isolation: nil)
    // drainCommands 只拿命令,不碰 rename
    XCTAssertEqual(s.drainCommands().count, 1)
    XCTAssertEqual(s.pendingRename(crewId: "c"), "起个名")
    // drainRenames 只拿 rename,不碰命令(命令已被上面 drain 掉,这里重造一条验证隔离)
    s.enqueueStartSession(crewId: "c", brief: "再干", runner: nil, isolation: nil)
    XCTAssertEqual(s.drainRenames().count, 1)
    XCTAssertEqual(s.drainCommands().count, 1)
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd apps/pendingcrew && ./scripts/swiftc-check-controlstore.sh`(见 Step 4;或直接 `xcodebuild test`)
Expected: 编译失败 "value of type 'LocalCrewControlStore' has no member 'enqueueStartSession'"

- [ ] **Step 3: 实现** — 在 `LocalCrewControlStore.swift` 的 `// MARK: - Persistence` 之前插入命令队列区,并在文件末尾追加 `CrewCommand`:

```swift
    // MARK: - Command queue（helper 侧：start_session / create_child_crew）
    //
    // rename 是 last-write-wins 单文件；起 session / 建子 crew 可重复，用队列：
    // 每条一个独立文件 <crewId>.<uuid>.crewcmd.json，drain 时全读+删。

    /// 机长起 worker session：brief 必填（空则忽略）；runner/isolation 可选。
    func enqueueStartSession(crewId: String, brief: String, runner: String?, isolation: Bool?) {
        enqueue(CrewCommand(
            id: UUID().uuidString.lowercased(), crewId: crewId, kind: "start_session",
            brief: brief, runner: runner, isolation: isolation, title: nil,
            ts: ISO8601DateFormatter().string(from: Date())))
    }

    /// 机长以当前 crew 为父建子 crew：brief 必填；title 可选（不给 → app 侧地名占位）。
    func enqueueCreateChildCrew(crewId: String, brief: String, title: String?) {
        enqueue(CrewCommand(
            id: UUID().uuidString.lowercased(), crewId: crewId, kind: "create_child_crew",
            brief: brief, runner: nil, isolation: nil, title: title,
            ts: ISO8601DateFormatter().string(from: Date())))
    }

    private func enqueue(_ cmd: CrewCommand) {
        guard !cmd.brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let data = try? JSONEncoder().encode(cmd) else { return }
        let url = directory.appendingPathComponent("\(cmd.crewId).\(cmd.id)\(Self.cmdSuffix)")
        try? data.write(to: url, options: .atomic)
    }

    /// 排空全部待执行命令（目录监听 tick 调）：返回列表并删除对应文件。
    /// 执行由调用方做（CrewStore）。跨 crew 一并返回，调用方按 crewId 分派。
    func drainCommands() -> [CrewCommand] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        var out: [CrewCommand] = []
        for url in files where url.lastPathComponent.hasSuffix(Self.cmdSuffix) {
            guard let data = try? Data(contentsOf: url),
                  let cmd = try? JSONDecoder().decode(CrewCommand.self, from: data) else { continue }
            out.append(cmd)
            try? FileManager.default.removeItem(at: url)
        }
        return out.sorted { $0.ts < $1.ts }
    }
```

在 `// MARK: - Persistence` 区加后缀常量(紧挨既有 `suffix`):

```swift
    private static let cmdSuffix = ".crewcmd.json"
```

在文件末尾 `CrewMetaChange` 之后追加:

```swift
/// 一条待执行的机长命令（起 session / 建子 crew）。`ts` 用于 drain 后按写入序执行。
struct CrewCommand: Codable, Equatable {
    let id: String
    let crewId: String
    let kind: String        // "start_session" | "create_child_crew"
    let brief: String
    let runner: String?     // start_session：nil=随 crew captainAgentKind；"claude"/"codex" 覆盖
    let isolation: Bool?    // start_session：nil/false=共享 crew 目录；true=独立 worktree
    let title: String?      // create_child_crew：nil=地名占位
    let ts: String
}
```

- [ ] **Step 4: 跑测试确认通过**

新建 `apps/pendingcrew/scripts/swiftc-check-controlstore.sh`(仿 crew-naming 的 standalone 校验,headless 可跑,绕开 `@testable` bundle 序边 tech-debt):

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
# LocalCrewControlStore 依赖 LocalWhiteboardStore.defaultDirectory；测试用注入目录，桩掉即可。
cat > "$TMP/stub.swift" <<'EOF'
import Foundation
enum LocalWhiteboardStore { static var defaultDirectory: URL { FileManager.default.temporaryDirectory } }
EOF
swiftc -o "$TMP/run" \
  Sources/Stores/LocalCrewControlStore.swift "$TMP/stub.swift" \
  Tests/PendingCrewTests/LocalCrewControlStoreMain.swift 2>&1
"$TMP/run"
```

新建 `Tests/PendingCrewTests/LocalCrewControlStoreMain.swift`(把 XCTest 断言翻成 `precondition` 的 `@main` 跑法,或直接内联检查)——列出与 Step 1 各断言等价的检查,末行 `print("controlstore checks OK")`。

Run: `chmod +x apps/pendingcrew/scripts/swiftc-check-controlstore.sh && apps/pendingcrew/scripts/swiftc-check-controlstore.sh`
Expected: `controlstore checks OK`（若本机 `xcodebuild test` bundle 可编译,亦可 `xcodebuild test -scheme PendingCrew -destination 'platform=macOS' -only-testing:PendingCrewTests/LocalCrewControlStoreTests`,两者择一,swiftc 为准。）

- [ ] **Step 5: Commit**

```bash
git add apps/pendingcrew/Sources/Stores/LocalCrewControlStore.swift \
        apps/pendingcrew/Tests/PendingCrewTests/LocalCrewControlStoreTests.swift \
        apps/pendingcrew/Tests/PendingCrewTests/LocalCrewControlStoreMain.swift \
        apps/pendingcrew/scripts/swiftc-check-controlstore.sh
git commit -m "$(cat <<'EOF'
feat(pendingcrew): 控制通道加命令队列(CrewCommand + enqueue + drain)

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `LocalCrewStore.depth(of:)` 深度 helper(子 crew cap 用)

**Files:**
- Modify: `apps/pendingcrew/Sources/Stores/LocalCrewStore.swift`
- Test: `apps/pendingcrew/Tests/PendingCrewTests/LocalCrewStoreDepthTests.swift`(Create)

**Interfaces:**
- Consumes: 既有 `LocalCrew.parentCrewIds: [String]`、`crews: [String: LocalCrew]`
- Produces: `LocalCrewStore.depth(of crewId: String) -> Int`（无父=0；有父=1 + max(父深度)；带 visited 防脏数据成环无限递归）

- [ ] **Step 1: 写失败测试** — 新建 `LocalCrewStoreDepthTests.swift`:

```swift
import XCTest

final class LocalCrewStoreDepthTests: XCTestCase {
    /// 用注入目录起干净 store，直接建链：a ← b ← c ← d（b 的父是 a…）。
    private func freshStore() -> LocalCrewStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("crewdepth-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return LocalCrewStore(directory: dir)
    }

    func testRootDepthZero() {
        let s = freshStore()
        _ = s.createCrew(.init(title: "root", workingDirectory: "/tmp", captainAgentKind: "codex", machineId: nil))
        let root = s.allCrews().first!.id
        XCTAssertEqual(s.depth(of: root), 0)
    }

    func testChainDepthCounts() throws {
        let s = freshStore()
        let a = s.createCrew(.init(title: "a", workingDirectory: "/tmp", captainAgentKind: "codex", machineId: nil)).crewId
        let b = s.createCrew(.init(title: "b", workingDirectory: "/tmp", captainAgentKind: "codex", machineId: nil)).crewId
        let c = s.createCrew(.init(title: "c", workingDirectory: "/tmp", captainAgentKind: "codex", machineId: nil)).crewId
        try s.attachParent(crewId: b, parentCrewId: a)
        try s.attachParent(crewId: c, parentCrewId: b)
        XCTAssertEqual(s.depth(of: a), 0)
        XCTAssertEqual(s.depth(of: b), 1)
        XCTAssertEqual(s.depth(of: c), 2)
    }

    func testUnknownCrewDepthZero() {
        XCTAssertEqual(freshStore().depth(of: "local-nope"), 0)
    }
}
```

> **实现者注**:核对 `CreateCrewRequest` 与 `createCrew`/`allCrews`/`LocalCrewStore(directory:)` 的真实签名(见 `LocalCrewStore.swift:88`、`:74` 及 init),测试构造按真实签名对齐;上面 `.init(title:workingDirectory:captainAgentKind:machineId:)` 若与真实结构体字段不符,以真实字段为准(不新增字段)。

- [ ] **Step 2: 跑测试确认失败**

Run: `apps/pendingcrew/scripts/swiftc-check-depth.sh`(仿 Task 1 的 swiftc 校验,或 `xcodebuild test -only-testing:PendingCrewTests/LocalCrewStoreDepthTests`)
Expected: 编译失败 "has no member 'depth'"

- [ ] **Step 3: 实现** — 在 `LocalCrewStore.swift` 的 `descendants(of:)`(:169)附近加:

```swift
    /// 沿父边算深度：无父 = 0，否则 1 + max(父深度)。带 visited 防脏数据成环无限递归。
    /// 用于 create_child_crew 前的深度 cap 检查（根 depth 0）。
    func depth(of crewId: String, visited: Set<String> = []) -> Int {
        guard let crew = crews[crewId], !crew.parentCrewIds.isEmpty else { return 0 }
        guard !visited.contains(crewId) else { return 0 } // 环自保
        let next = visited.union([crewId])
        return 1 + (crew.parentCrewIds.map { depth(of: $0, visited: next) }.max() ?? 0)
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `apps/pendingcrew/scripts/swiftc-check-depth.sh`
Expected: `depth checks OK`

- [ ] **Step 5: Commit**

```bash
git add apps/pendingcrew/Sources/Stores/LocalCrewStore.swift \
        apps/pendingcrew/Tests/PendingCrewTests/LocalCrewStoreDepthTests.swift \
        apps/pendingcrew/scripts/swiftc-check-depth.sh apps/pendingcrew/Tests/PendingCrewTests/LocalCrewStoreDepthMain.swift
git commit -m "$(cat <<'EOF'
feat(pendingcrew): LocalCrewStore.depth(of:) 深度 helper（子 crew cap 用）

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: McpServer 注册 `start_session` + `create_child_crew` 两工具

**Files:**
- Modify: `apps/pendingcrew/Sources/Mcp/McpServer.swift`(`tools/list` isCaptain 分支 :104-128、`handleToolCall` :141-213)
- Test: `apps/pendingcrew/Tests/PendingCrewTests/McpServerCaptainSpawnTests.swift`(Create)

**Interfaces:**
- Consumes: `LocalCrewControlStore.enqueueStartSession/enqueueCreateChildCrew`(Task 1);既有 `self.control`、`self.isCaptain`、`self.crewId`、`toolResult(id:text:)`
- Produces: 两个 MCP 工具的 `tools/list` 声明 + `handleToolCall` 分支

- [ ] **Step 1: 写失败测试** — 新建 `McpServerCaptainSpawnTests.swift`。构造一个注入临时目录的 `LocalCrewControlStore`,用 `isCaptain: true` 的 `McpServer`,发 `tools/call` JSON,断言命令入队;`isCaptain: false` 时断言被拒且不入队:

```swift
import XCTest

final class McpServerCaptainSpawnTests: XCTestCase {
    private func makeServer(isCaptain: Bool, dir: URL) -> McpServer {
        McpServer(store: LocalWhiteboardStore(directory: dir),
                  approvals: LocalApprovalStore(directory: dir),
                  control: LocalCrewControlStore(directory: dir),
                  crewId: "local-x", sessionId: "cap", isCaptain: isCaptain, sessionLabel: "Captain")
    }
    private func tmp() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("mcpspawn-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d
    }
    private func call(_ s: McpServer, _ name: String, _ args: [String: Any]) -> String? {
        let obj: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                  "params": ["name": name, "arguments": args]]
        let line = String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
        return s.handleLine(line)
    }

    func testStartSessionEnqueues() {
        let dir = tmp()
        let s = makeServer(isCaptain: true, dir: dir)
        _ = call(s, "start_session", ["brief": "修登录闪退", "runner": "claude", "isolation": true])
        let cmds = LocalCrewControlStore(directory: dir).drainCommands()
        XCTAssertEqual(cmds.count, 1)
        XCTAssertEqual(cmds[0].kind, "start_session")
        XCTAssertEqual(cmds[0].crewId, "local-x")
        XCTAssertEqual(cmds[0].brief, "修登录闪退")
        XCTAssertEqual(cmds[0].runner, "claude")
        XCTAssertEqual(cmds[0].isolation, true)
    }

    func testCreateChildCrewEnqueues() {
        let dir = tmp()
        _ = call(makeServer(isCaptain: true, dir: dir), "create_child_crew", ["brief": "做支付", "title": "支付"])
        let cmds = LocalCrewControlStore(directory: dir).drainCommands()
        XCTAssertEqual(cmds.count, 1)
        XCTAssertEqual(cmds[0].kind, "create_child_crew")
        XCTAssertEqual(cmds[0].title, "支付")
    }

    func testEmptyBriefRejectedNoEnqueue() {
        let dir = tmp()
        let out = call(makeServer(isCaptain: true, dir: dir), "start_session", ["brief": "   "])
        XCTAssertTrue((out ?? "").contains("ERROR"))
        XCTAssertTrue(LocalCrewControlStore(directory: dir).drainCommands().isEmpty)
    }

    func testNonCaptainRejectedNoEnqueue() {
        let dir = tmp()
        let out = call(makeServer(isCaptain: false, dir: dir), "start_session", ["brief": "干活"])
        XCTAssertTrue((out ?? "").contains("仅机长可用"))
        XCTAssertTrue(LocalCrewControlStore(directory: dir).drainCommands().isEmpty)
    }
}
```

> **实现者注**:核对 `McpServer.init` 真实签名(`McpServer.swift:27`)、`LocalWhiteboardStore(directory:)`/`LocalApprovalStore(directory:)` 是否支持注入目录;若某 store 无 `directory:` init,用其 `.shared` 并在 setUp 里指向临时目录,或按真实构造方式对齐。此测试文件依赖 app 源直编进 bundle(与 `LocalCrewControlStoreTests` 一致);若本机 `xcodebuild test` bundle 编不过(既有 `@testable` 序边 tech-debt),以 Task 7 的 `xcodebuild build` 集成编译 + 手工发一行 JSON 冒烟为准。

- [ ] **Step 2: 跑测试确认失败**

Run: `xcodebuild test -scheme PendingCrew -destination 'platform=macOS' -only-testing:PendingCrewTests/McpServerCaptainSpawnTests 2>&1 | tail -20`
Expected: FAIL — `tools/call` 收到未知工具 `start_session`,`drainCommands()` 为空,断言不通过。

- [ ] **Step 3: 实现** — (a) 在 `tools/list` 的 `if isCaptain {` 块(:104,`rename_crew` append 之后)追加两个工具声明:

```swift
                tools.append([
                    "name": "start_session",
                    "description": "（机长专用）在当前 crew 里起一个 worker session 去干一件明确的编码任务。brief 写清要干什么。runner 默认随本 crew（不填即可），可填 \"claude\"/\"codex\" 覆盖。isolation 默认 false（与你共享 crew 目录）；只有当这件事会大改文件、想隔离到独立 worktree 时才传 true。起完 worker 会自己报到，你在群聊看得到。",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "brief": ["type": "string", "description": "要这个 session 干的明确任务。"],
                            "runner": ["type": "string", "enum": ["claude", "codex"]],
                            "isolation": ["type": "boolean"],
                        ],
                        "required": ["brief"],
                    ],
                ])
                tools.append([
                    "name": "create_child_crew",
                    "description": "（机长专用）以当前 crew 为父，建一个子 crew。**只在一块事大到该独立成组、要有自己的机长和群聊时才拆，别滥拆。**子 crew 继承本 crew 的工作目录与机长类型，会自动起自己的机长，brief 作为它的开场任务。title 可不填（自动取个地名，子机长之后自己改名）。有子 crew 深度上限，太深会被拒。",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "brief": ["type": "string", "description": "这个子 crew 要干的事（子机长的开场任务）。"],
                            "title": ["type": "string", "description": "可选：短标签名。不填自动取地名。"],
                        ],
                        "required": ["brief"],
                    ],
                ])
```

(b) 在 `handleToolCall` 的 `switch name`(:142)里,`rename_crew` case 之后、`default` 之前加两个 case:

```swift
        case "start_session":
            guard isCaptain else { return toolResult(id: id, text: "ERROR: 仅机长可用") }
            let brief = ((args["brief"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !brief.isEmpty else { return toolResult(id: id, text: "ERROR: brief 不能为空") }
            let runner = (args["runner"] as? String).flatMap { ["claude", "codex"].contains($0) ? $0 : nil }
            let isolation = args["isolation"] as? Bool
            control.enqueueStartSession(crewId: crewId, brief: brief, runner: runner, isolation: isolation)
            return toolResult(id: id, text: "已安排起 session：\(brief)。它起来后会在群聊报到。")
        case "create_child_crew":
            guard isCaptain else { return toolResult(id: id, text: "ERROR: 仅机长可用") }
            let brief = ((args["brief"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !brief.isEmpty else { return toolResult(id: id, text: "ERROR: brief 不能为空") }
            let rawTitle = (args["title"] as? String) ?? ""
            let title = rawTitle.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            control.enqueueCreateChildCrew(crewId: crewId, brief: brief, title: title.isEmpty ? nil : title)
            return toolResult(id: id, text: "已安排建子 crew。它起来后子机长会报到。")
```

- [ ] **Step 4: 跑测试确认通过**

Run: `xcodebuild test -scheme PendingCrew -destination 'platform=macOS' -only-testing:PendingCrewTests/McpServerCaptainSpawnTests 2>&1 | tail -20`
Expected: PASS（若 bundle 编不过,以 Task 7 build + 冒烟为准，本步标注 deferred-to-T7）

- [ ] **Step 5: Commit**

```bash
git add apps/pendingcrew/Sources/Mcp/McpServer.swift \
        apps/pendingcrew/Tests/PendingCrewTests/McpServerCaptainSpawnTests.swift
git commit -m "$(cat <<'EOF'
feat(pendingcrew): McpServer 加机长专用 start_session / create_child_crew 工具

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: CrewStore 排空命令 + create_child_crew 执行 + sessionSpawnRequest

**Files:**
- Modify: `apps/pendingcrew/Sources/Stores/CrewStore.swift`(drain 区 :264-269、`captainAutostartRequest` :35、createCrew/attachParent :179-215)

**Interfaces:**
- Consumes: `LocalCrewControlStore.shared.drainCommands()`(Task 1)、`LocalCrewStore.shared.depth(of:)`(Task 2)、既有 `backend.createCrew`/`attachParent`、`captainAutostartRequest`、`LocalWhiteboardStore.shared.appendSystemMessage`(核对真实方法名)
- Produces:
  - `CrewStore.sessionSpawnRequest: SessionSpawnRequest?`(`@Published`)，`struct SessionSpawnRequest: Equatable { let crewId: String; let brief: String; let runner: String?; let isolation: Bool }`
  - `CrewStore.drainPendingCommands() async`（在既有目录监听 tick 里连同 rename 一起调）

- [ ] **Step 1: 阅读现状,确定接线点**(无测试步)。确认既有排空方法名(`CrewStore.swift:264` 附近,`drainRenames` 落地那个 `func`)与 renameWatch 订阅点(:257)。`create_child_crew` 深度 cap 走 `LocalCrewStore.shared.depth(of: parentId)`;子 crew 继承父的 `workingDirectory`/`captainAgentKind`(从 `LocalCrewStore.shared.crews[parentId]` 或已加载的 detail 取)。

- [ ] **Step 2: 写失败测试** — 深度 cap 与命令路由靠一个纯逻辑函数便于测。在 CrewStore 里抽 `static func shouldRejectChild(depthOfParent d: Int, cap: Int = 3) -> Bool { d + 1 > cap }`,新建 `Tests/PendingCrewTests/CrewStoreChildDepthTests.swift`:

```swift
import XCTest

final class CrewStoreChildDepthTests: XCTestCase {
    func testDepthCapBoundary() {
        XCTAssertFalse(CrewStore.shouldRejectChild(depthOfParent: 0)) // 建成 depth1
        XCTAssertFalse(CrewStore.shouldRejectChild(depthOfParent: 2)) // 建成 depth3，允许
        XCTAssertTrue(CrewStore.shouldRejectChild(depthOfParent: 3))  // 会成 depth4，拒
    }
}
```

- [ ] **Step 3: 跑测试确认失败**

Run: `xcodebuild test -scheme PendingCrew -destination 'platform=macOS' -only-testing:PendingCrewTests/CrewStoreChildDepthTests 2>&1 | tail -15`
Expected: FAIL "has no member 'shouldRejectChild'"

- [ ] **Step 4: 实现** — 在 `CrewStore.swift`:

(a) 加 published 请求 + 结构体(挨着 `captainAutostartRequest` :35):

```swift
    /// start_session 命令排空后的一次性请求 —— `MacRootView`（持 CrewSessionRunner）观察它调
    /// `runner.startForBrief`，起完置 nil（与 captainAutostartRequest 同模式）。
    @Published var sessionSpawnRequest: SessionSpawnRequest?
```

文件内(或同目录新 struct)加:

```swift
struct SessionSpawnRequest: Equatable {
    let crewId: String
    let brief: String
    let runner: String?   // nil=随 crew；"claude"/"codex"
    let isolation: Bool
}
```

(b) 加深度 cap 纯函数:

```swift
    /// 子 crew 深度 cap（根 depth 0，最长链 根→c1→c2→c3 = depth3）。
    static func shouldRejectChild(depthOfParent d: Int, cap: Int = 3) -> Bool { d + 1 > cap }
```

(c) 加命令排空 + 执行(在既有 rename 排空 tick 里追加调用 `await drainPendingCommands()`):

```swift
    /// 排空机长命令通道，逐条执行。start_session → 发 sessionSpawnRequest（MacRootView 起）；
    /// create_child_crew → 深度 cap → createCrew + attachParent + 自动起子机长 + 父白板回执。
    func drainPendingCommands() async {
        let cmds = LocalCrewControlStore.shared.drainCommands()
        guard !cmds.isEmpty else { return }
        for cmd in cmds {
            switch cmd.kind {
            case "start_session":
                sessionSpawnRequest = SessionSpawnRequest(
                    crewId: cmd.crewId, brief: cmd.brief,
                    runner: cmd.runner, isolation: cmd.isolation ?? false)
            case "create_child_crew":
                await executeCreateChildCrew(cmd)
            default:
                break
            }
        }
    }

    private func executeCreateChildCrew(_ cmd: CrewCommand) async {
        let parentId = cmd.crewId
        if Self.shouldRejectChild(depthOfParent: LocalCrewStore.shared.depth(of: parentId)) {
            LocalWhiteboardStore.shared.appendSystemMessage(
                crewId: parentId, text: "⚠️ 建子 crew 被拒：已达子 crew 深度上限（3 层）。")
            return
        }
        guard let parent = LocalCrewStore.shared.crews[parentId],
              let wd = parent.workingDirectory, !wd.isEmpty else {
            LocalWhiteboardStore.shared.appendSystemMessage(
                crewId: parentId, text: "⚠️ 建子 crew 被拒：父 crew 无可继承的工作目录。")
            return
        }
        do {
            let request = CreateCrewRequest.make(
                title: cmd.title, workingDirectory: wd,
                captainAgentKind: parent.captainAgentKind, machineId: parent.machineId)
            let resp = try await createCrew(request)          // 既有：内部会置 captainAutostartRequest
            try await attachParent(crewId: resp.crewId, parentCrewId: parentId)
            LocalWhiteboardStore.shared.appendSystemMessage(
                crewId: parentId,
                text: "已建子 crew「\(cmd.title ?? resp.crewId)」，子机长将自动报到。")
        } catch {
            LocalWhiteboardStore.shared.appendSystemMessage(
                crewId: parentId, text: "⚠️ 建子 crew 失败：\(error.localizedDescription)")
        }
    }
```

在既有目录监听落地方法(:266 那个 `drainRenames` 落地 func)结尾追加 `await drainPendingCommands()`。

> **实现者注**:核对真实方法/字段名——`LocalWhiteboardStore.shared` 往 crew 白板写系统消息的方法(可能叫 `appendSystemMessage`/`appendSessionMessage`/`append`,以真实 API 为准)、`CreateCrewRequest.make(...)` 的真实工厂签名(见 `CrewDetailInspector.swift:184` 与 `CreateCrewSheet.swift:418` 的既有调用)、`LocalCrew.workingDirectory`/`captainAgentKind`/`machineId` 字段名(见 `LocalCrewStore.swift`)。上面按现有调用点推断,不符处以真实为准,**不新增字段/方法**。

- [ ] **Step 5: 跑测试确认通过**

Run: `xcodebuild test -scheme PendingCrew -destination 'platform=macOS' -only-testing:PendingCrewTests/CrewStoreChildDepthTests 2>&1 | tail -15`（或 Task 7 build 兜底）
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add apps/pendingcrew/Sources/Stores/CrewStore.swift \
        apps/pendingcrew/Tests/PendingCrewTests/CrewStoreChildDepthTests.swift
git commit -m "$(cat <<'EOF'
feat(pendingcrew): CrewStore 排空机长命令 — 建子 crew 执行 + start_session 请求转发

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: startForBrief 扩 runner/isolation + MacRootView 观察 sessionSpawnRequest

**Files:**
- Modify: `apps/pendingcrew/Sources/Mac/Services/CrewSessionRunner.swift`(`startForBrief` :394)
- Modify: `apps/pendingcrew/Sources/Mac/Views/MacRootView.swift`(观察 `captainAutostartRequest` 的 `.onChange` :48-60 旁边加一个)

**Interfaces:**
- Consumes: `CrewStore.sessionSpawnRequest`(Task 4)、`SessionWorkspace.resolve(crewDirectory:isolation:hint:)`(见 `SessionWorkspace.swift:8`)、既有 `LocalCodingAgentKind.captainDefault(_:)`
- Produces: `CrewSessionRunner.startForBrief(detail:backend:brief:runnerOverride:isolation:)`(在既有 3 参签名上加两个默认参,保持既有调用点不变)

- [ ] **Step 1: 扩 startForBrief 签名**（既有调用点用默认参不受影响）。改 `func startForBrief(detail:backend:brief:)` 为:

```swift
    func startForBrief(detail: CrewDetail, backend: PendingCrewBackend?, brief: String,
                       runnerOverride: LocalCodingAgentKind? = nil, isolation: Bool = false) async throws {
```

体内两处改动:
- kind 解析加 override:`let kind = runnerOverride ?? LocalCodingAgentKind.captainDefault(detail.crew.captainAgentKind)`
- workdir 解析走 isolation(替换原来直接用 crew 目录那行):

```swift
        let baseDir = URL(fileURLWithPath: (wd as NSString).expandingTildeInPath)
        let workdir = SessionWorkspace.resolve(crewDirectory: baseDir, isolation: isolation, hint: brief)
```

其余(世界观渲染、comms、`start(role: .worker, ...)`)不变,只把 `workdir` 用上面解析出的。`runner` 字符串 → `LocalCodingAgentKind`:调用方(MacRootView)负责把 `"claude"/"codex"` 映射成 `.claudeCode/.codex`(核对 `LocalCodingAgentKind` 真实 case 名),`nil` → 传 `runnerOverride: nil`。

- [ ] **Step 2: MacRootView 观察 sessionSpawnRequest** — 在既有 `.onChange(of: crewStore.captainAutostartRequest)`(:48)之后加:

```swift
        .onChange(of: crewStore.sessionSpawnRequest) { _, req in
            guard let req else { return }
            Task {
                let detail = try? await crewStore.loadDetail(req.crewId) // 核对真实取 detail 方法名
                if let detail {
                    let kind: LocalCodingAgentKind? = req.runner.flatMap {
                        $0 == "claude" ? .claudeCode : ($0 == "codex" ? .codex : nil)
                    }
                    try? await runner.startForBrief(detail: detail, backend: crewStore.currentBackendForSpawn(),
                                                    brief: req.brief, runnerOverride: kind, isolation: req.isolation)
                }
                crewStore.sessionSpawnRequest = nil
            }
        }
```

> **实现者注**:核对 MacRootView 里 `runner`、`crewStore` 的真实注入名与既有 `captainAutostartRequest` 那段是怎么拿 detail / backend 起 captain 的(`MacRootView.swift:48-60`),**照它同款写法**取 detail 和 backend(上面的 `loadDetail`/`currentBackendForSpawn` 是占位名,用既有真实方法替换)。`LocalCodingAgentKind` 的 case 名(`.claudeCode`/`.codex`)核对 `startForBrief` 既有体里的写法(Task 触及文件已见 `.claudeCode`/`.codex`)。

- [ ] **Step 3: 编译验证**（此为 app glue,无独立单测,靠 build 集成编译)

Run: `cd apps/pendingcrew && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add apps/pendingcrew/Sources/Mac/Services/CrewSessionRunner.swift \
        apps/pendingcrew/Sources/Mac/Views/MacRootView.swift
git commit -m "$(cat <<'EOF'
feat(pendingcrew): startForBrief 支持 runner/isolation + MacRootView 接 sessionSpawnRequest

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: 机长 prompt 更新 + 清 tech-debt:61

**Files:**
- Modify: `apps/pendingcrew/Resources/Prompts/crew-captain.zh.md`
- Modify: `docs/tech-debt.md`(:61 附近的 `start_session` 漂移条)

- [ ] **Step 1: prompt** — 在 crew-captain.zh.md 里找到既有 `start_session` 说明段:
  - 把 `start_session(brief, runner?)` 更新为 `start_session(brief, runner?, isolation?)`,补一句「isolation 默认关(与你共享 crew 目录);只有会大改文件、想隔离时才 true」。
  - 新增 `create_child_crew(brief, title?)` 用法:**只在「一块事大到该独立成组、要有自己的机长和群聊」时拆子 crew,别滥拆**;子 crew 继承工作目录/机长类型、自动起子机长;title 不给就自动地名、子机长自己 rename。
  - 若 prompt 里没有 start_session 段(仅 tech-debt 记了漂移),则在工具清单处新增两条。

- [ ] **Step 2: 清 tech-debt:61** — 把「captain prompt 提到的 `start_session` 工具其实没实装」那条标为 ✅ 已解决(附本计划日期 + 分支 `feat/captain-spawn`),不删条目、只翻状态。

- [ ] **Step 3: Commit**

```bash
git add apps/pendingcrew/Resources/Prompts/crew-captain.zh.md docs/tech-debt.md
git commit -m "$(cat <<'EOF'
docs(pendingcrew): 机长 prompt 补 create_child_crew/start_session + 清 tech-debt:61 漂移

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: 集成验证 + 账本

**Files:**
- 无源码改动(纯验证 + 账本)
- Modify: `docs/progress.md`、`docs/state/pendingcrew.md`(captain / async-delegation 条现状刷新)

- [ ] **Step 1: xcodegen**（新增了 test/源文件,重生 pbxproj 保证纳入）

Run: `cd apps/pendingcrew && xcodegen`
Expected: `Created project at .../PendingCrew.xcodeproj`

- [ ] **Step 2: 全量 swiftc 单测**（Task 1/2 的 headless 校验）

Run: `apps/pendingcrew/scripts/swiftc-check-controlstore.sh && apps/pendingcrew/scripts/swiftc-check-depth.sh`
Expected: 两个 `... checks OK`

- [ ] **Step 3: macOS build**

Run: `cd apps/pendingcrew && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4:（可选）xcodebuild test** — 若本机 PendingCrewTests bundle 可编译(既有 `@testable` 序边 tech-debt 若未复发):

Run: `cd apps/pendingcrew && xcodebuild test -scheme PendingCrew -destination 'platform=macOS' -only-testing:PendingCrewTests 2>&1 | tail -8`
Expected: 全绿;编不过则记为「沿用 swiftc + build 兜底」,不阻断。

- [ ] **Step 5: 账本** — `docs/state/pendingcrew.md`:`concepts/captain` 现状补「start_session/create_child_crew 已实装,机长可自主起 session/建子 crew(本地);真机 E2E 归 #443」,去掉「依赖 start_session 未实装先收口」;`concepts/async-delegation` 现状把「驾驶舱看差生 session」旁补机长自主 spawn 已落。`docs/progress.md` 顶部加一条本次 entry。真机活验尾巴并入 `20260626-qa` / #443。

- [ ] **Step 6: Commit**

```bash
git add docs/progress.md docs/state/pendingcrew.md apps/pendingcrew/PendingCrew.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
docs(pendingcrew): captain 自主 spawn 落地对账 — state/progress + 真机尾巴归 #443

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

## 真机活验尾巴（不阻断合并,归 #443 / `20260626-qa`）

- 真起 claude worker(`start_session runner:"claude"`)+ codex worker,看它在群聊报到。
- `start_session isolation:true` 在 git repo 里真开独立 worktree;非 git repo 优雅退回共享目录。
- `create_child_crew` 真建子 crew → 子机长自动报到 → 父白板出现回执 → 侧栏 DAG 显示父子边。
- 深度 cap:在 depth3 的 crew 里调 `create_child_crew` 收到「已达深度上限」。

## Global Constraints 覆盖自查

- 本地模式、不碰 edge/relay ✅(所有执行走 LocalCrewStore/LocalWhiteboardStore/本地 runner)
- 仅机长可见可调 ✅(Task 3 tools/list isCaptain 分支 + tools/call isCaptain 守卫 + Task 3 测试 `testNonCaptainRejectedNoEnqueue`)
- 全自主直接执行 ✅(命令排空即执行,无人类确认门)
- 深度 cap=3 硬编码 ✅(Task 2 depth + Task 4 shouldRejectChild + 测试边界)
- 命令后缀 `.crewcmd.json` 不冲突 ✅(Task 1)
- 离线 store 纯 Foundation ✅(Task 1 编进 helper + bundle)
- 真机验记尾巴、验收门=swiftc+build ✅(Task 7)
