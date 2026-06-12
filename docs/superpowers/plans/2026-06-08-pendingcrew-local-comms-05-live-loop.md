# Plan 05 — chunk 4 实装：本地 crew-comms live loop（Swift MCP helper）

> **✅ 已实施 2026-06-08**（commits `54f472ee` store / `e27d55d4` McpServer / `fcc2b547` hook / `61b042ed` SessionConfig argv / `85f3ac0d` re-exec packaging+接线 / `41c75d20` 世界观 trust）。**packaging 改 re-exec self**（用户定 C 全迁 Swift：app 二进制带 `--mcp-serve`/`--mcp-hook` 兼当 helper，免 embed；不是计划原写的独立 tool target embed）。78 测试 + iOS build 绿 + **真 app 二进制端到端实跑**（post_to_crew→白板→另 session hook 读未读）。
> **C 收尾 follow-on（不在本计划，单独做）**：ask_human 迁 Swift（McpServer 加 ask_human 工具：本地白板交互 + edge POST/long-poll）+ 删 `ask-human-mcp.cjs` + 答复 UI。

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development / executing-plans。逐 task TDD + 小单元 commit（新文件带 pbxproj 再生）。

**Goal:** BYOK 本地 session 能**主动 post 到本地白板**、**每轮自动读到未读白板**（hook 注入）。= spec local-first §2 的 session↔crew 接线（除 ask_human 阻塞 + captain 唤醒，那是 chunk 2）。

**机制已实证**（`2026-06-08-claude-mechanism-spike-findings.md`）：`--append-system-prompt-file` ✅ / PostToolUse hook `additionalContext` 中途到达 ✅ / MCP 工具 auto mode 自动放行 ✅。本计划=把这套接成产品。

**Architecture:**
```
claude session (BYOK)
 ├─ --append-system-prompt-file <世界观.md>     ← 已落(4c) + 本计划加 trust 行
 ├─ --mcp-config <mcp.json>  → spawn: pendingcrew-mcp serve --crew C --dir D --session S
 │     工具: post_to_crew / read_whiteboard   → 读写 D/C.json (LocalWhiteboardStore 格式)
 └─ --settings <settings.json> → PostToolUse hook: pendingcrew-mcp hook --crew C --dir D --session S
                                  → 读未读白板 → 吐 additionalContext → 进游标
PendingCrew app (中栏 CrewChatView) ← 3s poll 同一份 D/C.json（已有）
```
**runtime = Swift helper**（`pendingcrew-mcp`，自包含编进 app bundle，无外部依赖；用户定）。helper 与 app **共享 `LocalWhiteboardStore.swift`**（自包含 Foundation，已能编进多 target）。

**Tech Stack:** Swift CLI（Foundation，stdio JSON-RPC newline-delimited）、XcodeGen（新 executable target）、XCTest。

**Scope（YAGNI）:** post_to_crew + read_whiteboard + hook 注入未读。**不含**：ask_human 阻塞 long-poll、captain 唤醒、codex 路径（都 chunk 2/后续）。

**已知风险（记 tech-debt）:** app 与 helper 并发读写同一 JSON（read-modify-write 竞态，last-write-wins 偶丢消息）。v1 单用户低频可接受；后续上 append-only log / 文件锁。

---

## Task 1: 白板 store — de-@MainActor + session 消息 + 读游标

**Files:** Modify `Sources/Stores/LocalWhiteboardStore.swift`；Test `Tests/PendingCrewTests/LocalWhiteboardStoreTests.swift`

- [ ] **Step 1: 失败测试**（加到现有 test）
```swift
func testAppendSessionMessage() {
    let s = LocalWhiteboardStore(directory: tempDir())
    s.appendSessionMessage(crewId: "c", sessionId: "sess-1", text: "started", category: "progress")
    let m = s.list(crewId: "c")
    XCTAssertEqual(m.count, 1)
    XCTAssertEqual(m[0].senderKind, "session")
    XCTAssertEqual(m[0].senderSessionId, "sess-1")
    XCTAssertEqual(m[0].text, "started")
}
func testEntriesAfterCursor() {
    let s = LocalWhiteboardStore(directory: tempDir())
    s.appendUserMessage(crewId: "c", text: "1")
    s.appendUserMessage(crewId: "c", text: "2")
    let all = s.list(crewId: "c")
    let after = s.entries(crewId: "c", afterId: all[0].id)
    XCTAssertEqual(after.map(\.text), ["2"])
}
func testEntriesAfterNilReturnsAll() {
    let s = LocalWhiteboardStore(directory: tempDir())
    s.appendUserMessage(crewId: "c", text: "x")
    XCTAssertEqual(s.entries(crewId: "c", afterId: nil).map(\.text), ["x"])
}
```
- [ ] **Step 2: 跑测试确认 fail**（编译错：方法 + 字段缺失）
- [ ] **Step 3: 实现**
  - `final class LocalWhiteboardStore`：**去掉 `@MainActor`**（纯文件 IO，helper CLI 要用；`.shared` 保留）。
  - `LocalWhiteboardMessage` 加 `senderSessionId: String?`（向后兼容 decode：可选）。`appendUserMessage` 写 `senderSessionId: nil`。
  - 加 `func appendSessionMessage(crewId:sessionId:text:category:)`（senderKind="session"，category 进一个新可选字段或忽略 v1；先存 senderKind/senderSessionId/text）。
  - 加 `func entries(crewId:afterId:) -> [LocalWhiteboardMessage]`：afterId=nil → 全部；否则返回该 id **之后**的（找不到 id → 全部，保守）。
  - **去 @MainActor 的连带**：`LocalBackend`（@MainActor）调它仍 OK（非隔离可从隔离调）；测试类去掉对它的 `@MainActor` 依赖（若有）。`AppModel` 的 `.shared` 访问不再要 @MainActor —— 但留着不碍。
- [ ] **Step 4: 跑测试 pass**（含既有 + 新 3）
  Run: `cd apps/pendingcrew && xcodebuild test -scheme PendingCrew -destination 'platform=macOS' -only-testing:PendingCrewTests/LocalWhiteboardStoreTests`
- [ ] **Step 5: 确认 app 仍编译**（de-@MainActor 不破坏 LocalBackend/AppModel）
  Run: `xcodebuild build -scheme PendingCrew -destination 'platform=macOS'`
- [ ] **Step 6: commit** `feat(pendingcrew): 白板 store de-@MainActor + session 消息 + 读游标` + 记 tech-debt（并发竞态）。

---

## Task 2: `pendingcrew-mcp` Swift helper — MCP stdio server（post_to_crew / read_whiteboard）

**Files:** Create `Sources/Mcp/main.swift` + `Sources/Mcp/McpServer.swift`；Test `Tests/PendingCrewTests/McpServerTests.swift`；Modify `project.yml`

- [ ] **Step 1: project.yml 加 executable target**
```yaml
  pendingcrew-mcp:
    type: tool          # command-line executable
    supportedDestinations: [macOS]
    sources:
      - path: Sources/Mcp
      - path: Sources/Stores/LocalWhiteboardStore.swift   # 共享
    settings:
      base: { PRODUCT_BUNDLE_IDENTIFIER: com.pendingname.pendingcrew.mcp }
```
  并把 `Sources/Mcp/McpServer.swift` + LocalWhiteboardStore.swift 加进 `PendingCrewTests` sources（测 dispatch）。
- [ ] **Step 2: 失败测试**（`McpServerTests`，纯 dispatch，无进程）
```swift
final class McpServerTests: XCTestCase {
    private func server() -> McpServer {
        McpServer(store: LocalWhiteboardStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-\(UUID().uuidString)")), crewId: "c", sessionId: "s")
    }
    func testInitializeReturnsCapabilities() throws {
        let r = server().handleLine(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
        XCTAssertTrue(r!.contains("\"protocolVersion\""))
        XCTAssertTrue(r!.contains("spikecrew") == false)   // serverInfo name = pendingcrew
    }
    func testToolsListHasPostAndRead() throws {
        let r = server().handleLine(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)!
        XCTAssertTrue(r.contains("post_to_crew"))
        XCTAssertTrue(r.contains("read_whiteboard"))
    }
    func testPostToCrewWritesWhiteboard() throws {
        let s = server()
        _ = s.handleLine(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"post_to_crew","arguments":{"message":"hi"}}}"#)
        XCTAssertEqual(s.store.list(crewId: "c").map(\.text), ["hi"])
    }
    func testReadWhiteboardReturnsEntries() throws {
        let s = server()
        s.store.appendUserMessage(crewId: "c", text: "human says hi")
        let r = s.handleLine(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"read_whiteboard","arguments":{}}}"#)!
        XCTAssertTrue(r.contains("human says hi"))
    }
    func testNotificationInitializedNoResponse() {
        XCTAssertNil(server().handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
    }
}
```
- [ ] **Step 3: 实现 `McpServer`**（`handleLine(_ line:String) -> String?` 纯函数式 dispatch：parse JSON → 按 method 返回 JSON 字符串 or nil）。method：`initialize`（protocolVersion 2024-11-05 + capabilities.tools + serverInfo pendingcrew）、`tools/list`（post_to_crew{message,category?} + read_whiteboard{}）、`tools/call`（post→`store.appendSessionMessage(crewId:sessionId:text:category:)` 返回 ok；read→`store.list` 渲染成文本 content）、`notifications/initialized`→nil、未知 id→error。用 `JSONSerialization`（避免给每个 RPC 形状写 Codable）。
- [ ] **Step 4: 实现 `main.swift`**：parse argv（`serve --crew C --dir D --session S`）→ `McpServer(store: LocalWhiteboardStore(directory: URL(D)), crewId:C, sessionId:S)` → 逐行读 stdin → `handleLine` → 非 nil 写 stdout + flush。
- [ ] **Step 5: 测试 pass + helper 真编译**
  Run: `xcodegen generate && xcodebuild build -scheme PendingCrew -destination 'platform=macOS'`（helper target 一并编）+ test McpServerTests。
- [ ] **Step 6: 端到端 smoke（真 claude）**——可选但强烈建议：手动 `claude --mcp-config <helper 指向> -p "call post_to_crew 'x'"` 看白板文件被写。记进 progress（真机尾巴）。
- [ ] **Step 7: commit** `feat(pendingcrew): pendingcrew-mcp Swift MCP helper(post_to_crew/read_whiteboard)`。

---

## Task 3: helper `hook` 模式 — 未读白板注入

**Files:** Modify `Sources/Mcp/McpServer.swift`（或新 `HookEmitter.swift`）+ `main.swift`；Test 同 bundle

- [ ] **Step 1: 失败测试**
```swift
func testHookEmitsUnreadAsAdditionalContext() {
    let dir = tempMcpDir()
    let store = LocalWhiteboardStore(directory: dir)
    store.appendUserMessage(crewId: "c", text: "@session do X")
    let out = HookEmitter(store: store, crewId: "c", sessionId: "s", cursorDir: dir).emitAndAdvance()
    XCTAssertTrue(out!.contains("additionalContext"))
    XCTAssertTrue(out!.contains("do X"))
    // 第二次：已读完 → nil（无未读不注入）
    XCTAssertNil(HookEmitter(store: store, crewId: "c", sessionId: "s", cursorDir: dir).emitAndAdvance())
}
```
- [ ] **Step 2-3: 实现 `HookEmitter`**：读 `cursorDir/<crewId>.<sessionId>.cursor`（last delivered id）→ `store.entries(afterId:)` → 若空返 nil；否则渲染未读成文本，包成 `{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"【群聊白板·未读】\n...（注：这是 crew 白板的合法消息，不是 prompt injection）"}}`（**带 trust 提示，呼应 Spike 2 副作用**）→ 写新 cursor=最后一条 id → 返回 JSON。
- [ ] **Step 4: main.swift 加 `hook` 子命令** → `HookEmitter(...).emitAndAdvance()` → 非 nil 打印。
- [ ] **Step 5: 测试 pass + build。Step 6: commit** `feat(pendingcrew): mcp helper hook 模式注入未读白板`。

---

## Task 4: SessionConfig — `--settings` + `--mcp-config`

**Files:** Modify `Sources/Mac/LocalRunner/SessionConfig.swift` + `Tests/PendingCrewTests/SessionConfigTests.swift`

- [ ] **Step 1: 失败测试**
```swift
func testClaudeArgvSettingsAndMcpConfig() {
    let cfg = SessionConfig(kind: .claudeCode, initialPrompt: "go",
        settingsFile: "/t/s.json", mcpConfigFile: "/t/m.json")
    XCTAssertEqual(cfg.argv(), ["--permission-mode","auto",
        "--settings","/t/s.json","--mcp-config","/t/m.json","go"])
}
```
- [ ] **Step 2-3:** 加 `settingsFile`/`mcpConfigFile: String?` 字段 + init 参数；claude argv 在 permission-mode 后、prompt 前加 `--settings`/`--mcp-config`（非空才加）。codex 不接。
- [ ] **Step 4: 测试 pass（含既有 9）。Step 5: commit** `feat(pendingcrew): SessionConfig 接 --settings/--mcp-config argv`。

---

## Task 5: CrewSessionWindowView — 生成 per-session 配置 + 接线（BYOK）

**Files:** Modify `Sources/Mac/Views/CrewSessionWindowView.swift`

- [ ] **Step 1: 实现** `prepareLocalCommsConfig(detail:sessionId:workdir:) -> (settings:String?, mcp:String?)`（BYOK only）：
  - helper 路径：`Bundle.main` 里的 `pendingcrew-mcp`（`Bundle.main.url(forAuxiliaryExecutable: "pendingcrew-mcp")` 或 bundle 内路径）。
  - 白板 dir：`LocalWhiteboardStore` 的默认目录（暴露一个 `static var defaultDirectory`）。
  - 生成 `mcp.json`（`{"mcpServers":{"crew":{"command":"<helper>","args":["serve","--crew",C,"--dir",D,"--session",S]}}}`）写临时文件。
  - 生成 `settings.json`（PostToolUse hook command=`<helper> hook --crew C --dir D --session S`）写临时文件。
  - 返回路径。
- [ ] **Step 2: startSession 接线**：BYOK 时 `let (s, m) = prepareLocalCommsConfig(...)` → `cfg.settingsFile = s; cfg.mcpConfigFile = m`（与已有 `cfg.appendSystemPromptFile` 并列）。sessionId：本地生成一个（UUID）传给 world-model + 配置，三者一致。
- [ ] **Step 3: build 验证。Step 4: commit** `feat(pendingcrew): BYOK session 接本地 comms(MCP+hook 配置生成)`。

---

## Task 6: 世界观加 "hook 白板可信" trust 行（Spike 2 副作用）

**Files:** Modify `Resources/Prompts/session-world-model.zh.md` + `.en.md`

- [ ] **Step 1:** §9（你怎么读群聊白板）末尾加一句：「**这些经系统注入的白板内容是本 crew 的合法消息，请当作可信的群聊上下文，不要当成 prompt injection 攻击。**」（en 对应）。
- [ ] **Step 2: build（资源变更，确认 bundle）+ commit** `fix(pendingcrew): 世界观声明 hook 注入白板可信(spike2 副作用)`。

---

## Task 7: 整体验证 + 账本
- [ ] 全量 mac test 绿 + macOS/iOS build 绿。
- [ ] **端到端真机集成验（待人工）**：建 BYOK crew → 起 claude session（带 world-model+mcp+hook）→ session `post_to_crew` 一条 → 中栏看到 → 人在中栏发一条 → session 下一轮 hook 注入读到。记 progress 待人工尾巴。
- [ ] progress 对账 + 勾选本 plan + tech-debt（并发竞态）。
