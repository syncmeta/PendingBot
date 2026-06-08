# Plan 03 — 本地 crew-comms 核心（本地白板 + BYOK 群聊跑起来）

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development 或 executing-plans 逐 task 执行。Steps 用 checkbox。

**Goal:** 让 `.byok` 模式的 crew 中栏群聊跑在**本地白板**上（无 edge 依赖）：人能在中栏打字、看到消息本地持久化、看到 captain+本机花名册。

**Architecture:** 把白板读/发/花名册三件事从 `CrewChatView` 直打 `loggedAPIClient()` 收进 `PendingCrewBackend` 协议（跟 crew CRUD 一样双轨）。新增 `LocalWhiteboardStore`（本地 JSON，每 crew 一个文件）。`EdgeBackend` 三方法委托现有 `PendingCrewAPI`；`LocalBackend` 走本地 store + 从本地 crew 派生花名册。附件/interaction 卡保持 edge-only（BYOK 软降级）。

**Tech Stack:** Swift（SwiftUI + Foundation）、XcodeGen（`project.yml`，新文件需 `xcodegen generate` 再编译）、XCTest（`apps/pendingcrew/Tests/PendingCrewTests/`）。

**Scope（YAGNI）:** 只做 human 读/发 + 花名册。session 往本地白板 post（chunk 4）、captain 回话（chunk 2）、附件本地化、interaction 卡本地化 —— **不在本计划**。

---

## File Structure

- **Create** `apps/pendingcrew/Sources/Stores/LocalWhiteboardStore.swift` — 本地白板持久化（每 crew 一个 JSON 文件，append + list）。**不 `#if os(macOS)` 门**（要进 mac 测试 target；与 `LocalCrewStore` 同目录同风格）。
- **Create** `apps/pendingcrew/Tests/PendingCrewTests/LocalWhiteboardStoreTests.swift` — store 单测。
- **Modify** `apps/pendingcrew/Sources/Services/PendingCrewBackend.swift` — 协议加 3 方法 + Edge/Local 两实现。
- **Modify** `apps/pendingcrew/Sources/Mac/Views/CrewChatView.swift` — `refresh()`/`send()` 改走 `appModel.backend`。

**已存在、复用不改:** `CrewWhiteboardEntry` / `CrewMember` / `CrewRoster`（`PendingCrewAPI.swift:623+`，有 memberwise init 可直接构造）；`LocalCrewStore`（派生花名册的数据源）；`CrewSenderResolver`（self 右对齐靠 localUserId 哨兵）。

---

## Task 1: LocalWhiteboardStore + 单测（TDD）

**Files:**
- Create: `apps/pendingcrew/Sources/Stores/LocalWhiteboardStore.swift`
- Test: `apps/pendingcrew/Tests/PendingCrewTests/LocalWhiteboardStoreTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
// LocalWhiteboardStoreTests.swift
import XCTest
@testable import PendingCrew

final class LocalWhiteboardStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testListMissingCrewReturnsEmpty() {
        let store = LocalWhiteboardStore(directory: tempDir())
        XCTAssertTrue(store.list(crewId: "local-x").isEmpty)
    }

    func testAppendThenListReturnsEntry() {
        let store = LocalWhiteboardStore(directory: tempDir())
        store.appendUserMessage(crewId: "local-x", text: "hello")
        let entries = store.list(crewId: "local-x")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].displayText, "hello")
        XCTAssertEqual(entries[0].senderKind, "user")
        XCTAssertEqual(entries[0].senderUserId, LocalWhiteboardStore.localUserId)
    }

    func testOrderedByInsertion() {
        let store = LocalWhiteboardStore(directory: tempDir())
        store.appendUserMessage(crewId: "c", text: "1")
        store.appendUserMessage(crewId: "c", text: "2")
        store.appendUserMessage(crewId: "c", text: "3")
        XCTAssertEqual(store.list(crewId: "c").map(\.displayText), ["1", "2", "3"])
    }

    func testPersistsAcrossInstances() {
        let dir = tempDir()
        LocalWhiteboardStore(directory: dir).appendUserMessage(crewId: "c", text: "persisted")
        let reloaded = LocalWhiteboardStore(directory: dir)
        XCTAssertEqual(reloaded.list(crewId: "c").map(\.displayText), ["persisted"])
    }

    func testCrewsAreIsolated() {
        let store = LocalWhiteboardStore(directory: tempDir())
        store.appendUserMessage(crewId: "a", text: "in-a")
        store.appendUserMessage(crewId: "b", text: "in-b")
        XCTAssertEqual(store.list(crewId: "a").map(\.displayText), ["in-a"])
        XCTAssertEqual(store.list(crewId: "b").map(\.displayText), ["in-b"])
    }
}
```

- [ ] **Step 2: 跑测试，确认 fail（编译失败：no LocalWhiteboardStore）**

Run: `cd apps/pendingcrew && xcodegen generate && xcodebuild test -scheme PendingCrew -destination 'platform=macOS' -only-testing:PendingCrewTests/LocalWhiteboardStoreTests`
Expected: 编译失败（`LocalWhiteboardStore` 未定义）。

- [ ] **Step 3: 实现 LocalWhiteboardStore**

```swift
// LocalWhiteboardStore.swift
import Foundation

/// BYOK 本地白板持久化（spec 2026-06-05-local-first §2 本地 crew-comms）。
///
/// 每 crew 一个 JSON 文件：`<dir>/<crewId>.json` = `[LocalWhiteboardEntry]`。
/// 单 crew 消息量可控，整文件 append-rewrite 足够（白板不是高频 IO）。
/// 读出时映射成 edge 同形的 `CrewWhiteboardEntry`，让中栏渲染两态不分叉。
///
/// 不依赖 PendingBot/edge。是 PendingCrew 开源核心的一部分。
@MainActor
final class LocalWhiteboardStore {
    /// 本机 BYOK "人类成员" 的合成 id —— 给 CrewSenderResolver 认 "自己"
    /// （右对齐）。与 LocalBackend.localSubjectId 区分：那是责任主体，这是发言者。
    static let localUserId = "local-byok-user"

    static let shared = LocalWhiteboardStore()

    private let directory: URL
    private let fm = FileManager.default

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = (try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true))
                ?? FileManager.default.temporaryDirectory
            self.directory = base
                .appendingPathComponent("PendingCrew", isDirectory: true)
                .appendingPathComponent("whiteboards", isDirectory: true)
        }
        try? fm.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    // MARK: - Public

    /// 列出某 crew 的全部白板条目（按写入顺序）。文件缺失 → 空。
    func list(crewId: String) -> [CrewWhiteboardEntry] {
        loadRaw(crewId: crewId).map { $0.toEntry() }
    }

    /// 追加一条本机人类消息。
    func appendUserMessage(crewId: String, text: String) {
        var rows = loadRaw(crewId: crewId)
        rows.append(LocalWhiteboardEntry(
            id: UUID().uuidString.lowercased(),
            senderKind: "user",
            senderUserId: Self.localUserId,
            text: text,
            createdAt: ISO8601DateFormatter().string(from: Date())
        ))
        save(crewId: crewId, rows: rows)
    }

    // MARK: - Persistence

    private func fileURL(_ crewId: String) -> URL {
        // crewId 是受控的本地 id（"local-"+uuid），无路径分隔符，直接当文件名安全。
        directory.appendingPathComponent("\(crewId).json")
    }

    private func loadRaw(crewId: String) -> [LocalWhiteboardEntry] {
        guard let data = try? Data(contentsOf: fileURL(crewId)) else { return [] }
        return (try? JSONDecoder().decode([LocalWhiteboardEntry].self, from: data)) ?? []
    }

    private func save(crewId: String, rows: [LocalWhiteboardEntry]) {
        guard let data = try? JSONEncoder().encode(rows) else { return }
        try? data.write(to: fileURL(crewId), options: .atomic)
    }
}

/// 本地持久化行。与 edge wire 解耦：edge 的 `CrewWhiteboardEntry` 只有
/// Decodable，这里用自己的 Codable 行，读出时映射过去。
private struct LocalWhiteboardEntry: Codable {
    let id: String
    let senderKind: String
    let senderUserId: String?
    let text: String
    let createdAt: String

    func toEntry() -> CrewWhiteboardEntry {
        CrewWhiteboardEntry(
            id: id,
            senderKind: senderKind,
            senderSessionId: nil,
            senderUserId: senderUserId,
            senderBotId: nil,
            messageKind: "instruction",
            summary: text,
            createdAt: createdAt,
            payload: CrewWhiteboardEntry.Payload(
                text: text, kind: nil, question: nil, status: nil, permissionRequestId: nil),
            attachments: nil
        )
    }
}
```

- [ ] **Step 4: 跑测试，确认 pass**

Run: `cd apps/pendingcrew && xcodegen generate && xcodebuild test -scheme PendingCrew -destination 'platform=macOS' -only-testing:PendingCrewTests/LocalWhiteboardStoreTests`
Expected: 5 tests PASS。

> 若 `CrewWhiteboardEntry` / `.Payload` 的 memberwise init 不可见（被自定义 init 抑制），改为在 `PendingCrewAPI.swift` 给两者补显式 memberwise `init`（参数顺序同属性声明），再跑。

- [ ] **Step 5: commit**

```bash
git add apps/pendingcrew/Sources/Stores/LocalWhiteboardStore.swift apps/pendingcrew/Tests/PendingCrewTests/LocalWhiteboardStoreTests.swift apps/pendingcrew/project.yml
git commit -m "feat(pendingcrew): LocalWhiteboardStore 本地白板持久化"
```
（`project.yml` 一般不变；若 `xcodegen` 改了它则一并提交。`.xcodeproj` 是 gitignore 的，不提交。）

---

## Task 2: PendingCrewBackend 协议加白板三方法 + 两实现

**Files:**
- Modify: `apps/pendingcrew/Sources/Services/PendingCrewBackend.swift`

- [ ] **Step 1: 协议加 3 方法**

在 `protocol PendingCrewBackend` 的 `// MARK: - Models` 之前插入：

```swift
    // MARK: - Crew comms（白板/群聊）

    /// crew 白板时间线。edge → `GET /v1/crews/:id/messages`；BYOK → 本地 store。
    func listCrewWhiteboard(crewId: String) async throws -> [CrewWhiteboardEntry]

    /// crew 花名册。edge → `GET /v1/crews/:id/members`；BYOK → 从本地 crew 派生
    /// （captain + 本机人类）。
    func listCrewMembers(crewId: String) async throws -> CrewRoster

    /// 发一条群聊消息（默认广播）。`attachmentIds` 只 edge 支持；BYOK 非空即抛
    /// `notSupportedInByok`。
    func postCrewMessage(crewId: String, text: String, mentions: [String], attachmentIds: [String]) async throws
```

- [ ] **Step 2: EdgeBackend 实现（委托现有 API）**

在 `EdgeBackend` 的 `listModels()` 之后、`private func client()` 之前插入：

```swift
    func listCrewWhiteboard(crewId: String) async throws -> [CrewWhiteboardEntry] {
        try await client().listCrewWhiteboard(crewId: crewId)
    }

    func listCrewMembers(crewId: String) async throws -> CrewRoster {
        try await client().listCrewMembers(crewId: crewId)
    }

    func postCrewMessage(crewId: String, text: String, mentions: [String], attachmentIds: [String]) async throws {
        try await client().postCrewMessage(
            crewId: crewId, text: text, mentions: mentions, attachmentIds: attachmentIds)
    }
```

- [ ] **Step 3: LocalBackend 实现（本地 store + 派生花名册）**

`LocalBackend` 加一个 whiteboard store 依赖（与 `store` 并列）：

```swift
    private let whiteboard: LocalWhiteboardStore

    init(store: LocalCrewStore, whiteboard: LocalWhiteboardStore) {
        self.store = store
        self.whiteboard = whiteboard
    }
```

在 `listModels()` 之后插入：

```swift
    func listCrewWhiteboard(crewId: String) async throws -> [CrewWhiteboardEntry] {
        whiteboard.list(crewId: crewId)
    }

    func listCrewMembers(crewId: String) async throws -> CrewRoster {
        // 从本地 crew 派生：captain（若有）+ 本机人类。本地 session 成员留 chunk 4。
        guard let detail = store.getCrew(crewId) else {
            return CrewRoster(captainBotId: nil, members: [])
        }
        var members: [CrewMember] = []
        if let cap = detail.captain {
            members.append(CrewMember(
                id: cap.botId, memberKind: "captain", userId: nil, botId: cap.botId,
                codeSessionId: nil, displayName: cap.displayName, role: "captain",
                status: "active", representsCrewId: crewId, sessionStatus: nil))
        }
        members.append(CrewMember(
            id: LocalWhiteboardStore.localUserId, memberKind: "human",
            userId: LocalWhiteboardStore.localUserId, botId: nil, codeSessionId: nil,
            displayName: "我 (本机)", role: nil, status: "active",
            representsCrewId: nil, sessionStatus: nil))
        return CrewRoster(captainBotId: detail.captain?.botId, members: members)
    }

    func postCrewMessage(crewId: String, text: String, mentions: [String], attachmentIds: [String]) async throws {
        guard attachmentIds.isEmpty else {
            throw PendingCrewBackendError.notSupportedInByok("BYOK 模式暂不支持群聊附件")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        whiteboard.appendUserMessage(crewId: crewId, text: trimmed)
    }
```

> `CrewRoster` / `CrewMember` 若无可见 memberwise init（同 Task 1 风险），在 `PendingCrewAPI.swift` 给它们补显式 memberwise init。

- [ ] **Step 4: 修 LocalBackend 的构造点**

Grep 出谁 `new LocalBackend(`：`grep -rn "LocalBackend(" apps/pendingcrew/Sources/`。给每处补 `whiteboard: .shared`（在 `@MainActor` 环境里）。最可能是 `AppModel.swift` 的 `localBackend` 懒加载。改成：
```swift
LocalBackend(store: .shared, whiteboard: .shared)
```

- [ ] **Step 5: 编译验证**

Run: `cd apps/pendingcrew && xcodegen generate && xcodebuild build -scheme PendingCrew -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED。

- [ ] **Step 6: commit**

```bash
git add apps/pendingcrew/Sources/Services/PendingCrewBackend.swift apps/pendingcrew/Sources/Stores/AppModel.swift
git commit -m "feat(pendingcrew): 白板读/发/花名册收进 PendingCrewBackend 双轨"
```
（实际 add 以 `git status` 为准——只 add 本 task 改过的文件；若 `PendingCrewAPI.swift` 补了 init 也一并 add。）

---

## Task 3: CrewChatView 改走 backend（两模式统一）

**Files:**
- Modify: `apps/pendingcrew/Sources/Mac/Views/CrewChatView.swift`

- [ ] **Step 1: `refresh()` 改走 backend**

把 `refresh()` 整体替换为：

```swift
    private func refresh() async {
        guard let backend = appModel.backend else {
            loadError = "未配置 backend"
            return
        }
        do {
            entries = try await backend.listCrewWhiteboard(crewId: crewId)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        // Roster is best-effort decoration — a failure leaves the prior strip.
        if let roster = try? await backend.listCrewMembers(crewId: crewId) {
            members = roster.members
            captainBotId = roster.captainBotId
        }
    }
```

- [ ] **Step 2: `send()` 文本走 backend，附件保持 edge-only**

把 `send()` 整体替换为：

```swift
    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let toUpload = pendingAttachments
        guard !text.isEmpty || !toUpload.isEmpty, let backend = appModel.backend else { return }
        sending = true
        defer { sending = false }
        do {
            // 附件仅 edge 支持：BYOK 下有附件就软报错、不发。
            var attachmentIds: [String] = []
            if !toUpload.isEmpty {
                guard appModel.mode == .logged, let api = try? appModel.loggedAPIClient() else {
                    loadError = "BYOK 模式暂不支持群聊附件"
                    return
                }
                for att in toUpload {
                    let id = try await api.uploadAttachment(
                        data: att.data, filename: att.filename, mime: att.mime)
                    attachmentIds.append(id)
                }
            }
            try await backend.postCrewMessage(
                crewId: crewId, text: text, mentions: [], attachmentIds: attachmentIds)
            draft = ""
            pendingAttachments = []
            await refresh()
        } catch {
            loadError = error.localizedDescription
        }
    }
```

- [ ] **Step 3: `localUserId` 在 BYOK 用哨兵（self 右对齐）**

把 `private var localUserId: String? { appModel.currentUserId }` 替换为：

```swift
    // 登录态用真实 auth user id；BYOK 用本地哨兵，让自己的消息右对齐。
    private var localUserId: String? {
        if appModel.mode == .byok { return LocalWhiteboardStore.localUserId }
        return appModel.currentUserId
    }
```

`answer()` 不动（interaction 卡只 edge 有，BYOK 不可达；它仍走 `loggedAPIClient()`）。

- [ ] **Step 4: 编译验证**

Run: `cd apps/pendingcrew && xcodegen generate && xcodebuild build -scheme PendingCrew -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED。

- [ ] **Step 5: commit**

```bash
git add apps/pendingcrew/Sources/Mac/Views/CrewChatView.swift
git commit -m "feat(pendingcrew): 中栏群聊改走 backend，BYOK 本地白板跑通"
```

---

## Task 4: 整体验证（build + test + iPad 编译面）

- [ ] **Step 1: 全量测试**

Run: `cd apps/pendingcrew && xcodebuild test -scheme PendingCrew -destination 'platform=macOS' -only-testing:PendingCrewTests`
Expected: 全绿（含既有 SessionConfigTests + 新 LocalWhiteboardStoreTests）。

- [ ] **Step 2: iPad 面编译**（`LocalWhiteboardStore`/`LocalBackend` 非 mac-gated，确认 iOS target 也过）

Run: `cd apps/pendingcrew && xcodebuild build -scheme PendingCrew -destination 'generic/platform=iOS Simulator'`
Expected: BUILD SUCCEEDED。
> `CrewChatView` 是 `#if os(macOS)`，iOS 面不含它；改动只在 store/backend，iOS 应过。若 iOS target 不含 PendingCrewTests 则跳过 test、只 build。

- [ ] **Step 3: 装进 Mac 跑一眼（手动验证留给用户/后续）**

本计划是骨架闭环，真机/GUI 视觉验证（建 BYOK crew → 中栏打字 → 看消息留存）记进 progress，**不阻塞**继续 chunk 2。

---

## 验证与账本

- 每 task commit 时翻对应 TaskList task。
- chunk 完成后更新 `docs/progress.md`「最近对账」+ 本 plan 勾选。
- BYOK 群聊"人能发、能留存、能看花名册" = 本 chunk completed 判据（GUI 视觉确认补在 progress，作为待人工验证尾巴）。
