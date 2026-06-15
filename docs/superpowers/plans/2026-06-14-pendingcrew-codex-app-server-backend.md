# PendingCrew codex app-server backend — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace codex's placeholder PTY terminal in PendingCrew with a native structured codex client driving the local `codex app-server` over stdio JSON-RPC — modeled on the codex desktop client. claude stays on the SwiftTerm terminal; only codex moves.

**Architecture:** Spawn `codex app-server` as a local child process (stdio, newline-delimited JSON-RPC 2.0 with `jsonrpc` omitted). A `SessionBackend` protocol lets the terminal-claude and appserver-codex implementations coexist behind `CrewSessionRun`. Codex `ThreadItem`s render into a structured `CodexTranscriptView`. World-model → `thread/start.developerInstructions`; per-turn whiteboard → `turn/start.additionalContext`; crew tools (post_to_crew/read_whiteboard/ask) → codex `mcp_servers`; approvals reuse the existing `LocalApprovalStore` UI (reply over stdin).

**Tech Stack:** Swift / SwiftUI / Combine, macOS-only (`#if os(macOS)`), XCTest, SwiftTerm (claude only), `codex app-server` (codex-cli, stdio JSON-RPC). Foundation-only logic files are unit-testable; app-target files verified by build.

---

## Reference docs (read before starting)

- Design spec: `docs/superpowers/specs/2026-06-14-codex-app-server-backend-design.md`
- Protocol bible (empirical, codex 0.137.0): `docs/superpowers/specs/2026-06-05-codex-app-server-reference.md`
- OpenAI app-server doc: https://developers.openai.com/codex/app-server
- Pattern references (verify license before copying code): `openai/codex` TUI (Apache-2.0), `shuto-S/codex-app-mobile` (SwiftUI)

## Environment constraints (CRITICAL — read first)

1. **`xcodebuild test` may fail in this hosted agent env** with `Pseudo Terminal Setup Error` (ptmx exhaustion in long sessions — see tech-debt). Primary verification is the **build**:
   ```
   cd apps/pendingcrew && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' build
   ```
   For unit tests, try `xcodebuild ... test` first; if the runner won't launch, fall back to the **swiftc-driver** pattern used in prior tasks (compile the Foundation-only files + a tiny `main` that runs assertions and exits non-zero on failure) or ask the user to run the suite.
2. **The `PendingCrewTests` target compiles an explicit file list, NOT the whole `Sources` tree.** SwiftUI files break the bundle. Every new **Foundation-only** logic file that needs unit tests must be added to the `PendingCrewTests` `sources:` list in `apps/pendingcrew/project.yml`, then regenerate: `cd apps/pendingcrew && xcodegen`. App-target files (backend actor, SwiftUI views) go to the `PendingCrew` target only.
3. **After any `project.yml` edit**, run `xcodegen` before building.
4. Keep everything behind `#if os(macOS)` — the LocalRunner module is macOS-only.

## File structure

**New — Foundation-only (app target + test target):**
- `Sources/Mac/LocalRunner/CodexAppServer/CodexRPCMessage.swift` — JSON-RPC envelope encode/decode + classification (response / serverRequest / notification).
- `Sources/Mac/LocalRunner/CodexAppServer/CodexRPCDispatcher.swift` — pure router: pairs responses to our outstanding requests (client id space), surfaces server requests (server id space) and notifications. No I/O.
- `Sources/Mac/LocalRunner/CodexAppServer/CodexProtocol.swift` — Codable param/result structs for the core-loop method subset.
- `Sources/Mac/LocalRunner/CodexAppServer/CodexThreadItem.swift` — `ThreadItem` union → display model with `.unknown` fallthrough.
- `Sources/Mac/LocalRunner/CodexAppServer/CodexTranscript.swift` — observable transcript state machine (apply item/turn events).

**New — app target only:**
- `Sources/Mac/LocalRunner/CodexAppServer/CodexAppServerConnection.swift` — actor: spawn `codex app-server`, wire stdin/stdout pipes to the codec + dispatcher.
- `Sources/Mac/LocalRunner/CodexAppServer/CodexAppServerBackend.swift` — `SessionBackend` impl: connection + transcript + approval bridge + context provider.
- `Sources/Mac/LocalRunner/SessionBackend.swift` — the protocol + shared `SessionStatus`.
- `Sources/Mac/Views/CodexTranscriptView.swift` — SwiftUI per-arm renderer.

**Modified:**
- `Sources/Mac/LocalRunner/AgentTerminalSession.swift` — conform to `SessionBackend`, use shared `SessionStatus`.
- `Sources/Mac/Services/CrewSessionRunner.swift` — `CrewSessionRun` holds `SessionBackend`; `start()` picks backend by kind.
- `Sources/Mac/LocalRunner/SessionConfig.swift` — codex branch → app-server spawn argv; drop placeholder.
- `Sources/Mac/LocalRunner/LocalCodingAgentSpec.swift` — `LocalCodingAgentEnv` codex billing guard (omit `OPENAI_API_KEY`).
- `Sources/Mac/LocalRunner/LocalSessionLaunch.swift` — codex variant (world-model string + whiteboard provider + codex MCP config).
- `Sources/Mac/Views/CrewSessionWindowView.swift` — inspector branches view by kind; codex launch path.
- `apps/pendingcrew/project.yml` — add new Foundation-only files to `PendingCrewTests` sources.
- `Tests/PendingCrewTests/SessionConfigTests.swift` — update codex argv tests.

---

## Phase 0 — `SessionBackend` abstraction (no behavior change; claude stays green)

### Task 0.1: Extract shared `SessionStatus` and `SessionBackend` protocol

**Files:**
- Create: `Sources/Mac/LocalRunner/SessionBackend.swift`
- Modify: `Sources/Mac/LocalRunner/AgentTerminalSession.swift`

- [ ] **Step 1: Write the protocol + status**

```swift
// SessionBackend.swift
#if os(macOS)
import Foundation
import Combine

/// Lifecycle of a running coding-agent session, independent of backend kind.
/// `.running` = the agent process is alive; `.exited(code)` = it ended.
/// (codex stays `.running` across turns; it only exits on stop/process death.)
public enum SessionStatus: Equatable {
    case running
    case exited(Int32?)
}

/// The control + lifecycle surface `CrewSessionRun` needs, shared by the
/// terminal (claude) and app-server (codex) backends. The *view* is chosen by
/// concrete type/kind; this protocol covers only control + status.
@MainActor
protocol SessionBackend: AnyObject {
    var status: SessionStatus { get }
    var statusPublisher: Published<SessionStatus>.Publisher { get }
    var kind: LocalCodingAgentKind { get }
    func send(_ text: String)
    func interrupt()
    func stop()
}
#endif
```

- [ ] **Step 2: Make `AgentTerminalSession` conform**

In `AgentTerminalSession.swift`: delete the nested `enum Status`, replace all `Status` with `SessionStatus`, change `@Published private(set) var status: Status = .running` → `@Published private(set) var status: SessionStatus = .running`, add conformance + publisher:

```swift
@MainActor
final class AgentTerminalSession: ObservableObject, SessionBackend {
    // ... existing ...
    @Published private(set) var status: SessionStatus = .running
    var statusPublisher: Published<SessionStatus>.Publisher { $status }
    // send/interrupt/stop already match the protocol
}
```

- [ ] **Step 3: Update `CrewSessionRun` to the shared type**

In `CrewSessionRunner.swift`, change `Self.map(terminalSession.status, ...)` paths: `private static func map(_ status: SessionStatus, ...)` (was `AgentTerminalSession.Status`). No other logic change — `.running` / `.exited(code)` cases are identical.

- [ ] **Step 4: Build (claude path unaffected)**

```
cd apps/pendingcrew && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```
git add apps/pendingcrew/Sources/Mac/LocalRunner/SessionBackend.swift apps/pendingcrew/Sources/Mac/LocalRunner/AgentTerminalSession.swift apps/pendingcrew/Sources/Mac/Services/CrewSessionRunner.swift
git commit -m "pendingcrew: 抽 SessionBackend protocol + 共享 SessionStatus(claude conform,无行为变化)"
```

### Task 0.2: `CrewSessionRun` holds `SessionBackend` instead of concrete `AgentTerminalSession`

**Files:**
- Modify: `Sources/Mac/Services/CrewSessionRunner.swift`
- Modify: `Sources/Mac/Views/AgentTerminalView.swift` (accessor), `Sources/Mac/Views/CrewSessionWindowView.swift` (terminalView access)

- [ ] **Step 1: Generalize the stored property**

In `CrewSessionRun`: rename `let terminalSession: AgentTerminalSession` → `let backend: SessionBackend`. Update `init` param. Update `observeTerminalStatus()` to iterate `backend.statusPublisher.values`. Update `send`/`interrupt`/`stop` to call `backend`. Initial `status = Self.map(backend.status, cancelled: false)`.

- [ ] **Step 2: Add a typed terminal accessor for the view**

The claude view needs `LocalProcessTerminalView`. Add to `CrewSessionRun`:
```swift
/// The SwiftTerm view, only when this run's backend is the terminal (claude).
var terminalView: LocalProcessTerminalView? {
    (backend as? AgentTerminalSession)?.terminalView
}
```

- [ ] **Step 3: Fix call sites**

`CrewSessionRunner.start()` constructs `terminalSession:` → pass `backend:` (still `AgentTerminalSession(...)` for now — codex factory comes in Phase 3). In `CrewSessionWindowView.swift`, wherever `run.terminalSession.terminalView` is used, use `run.terminalView` (optional) and render the terminal only when non-nil (codex branch added in Phase 5).

- [ ] **Step 4: Build**

```
cd apps/pendingcrew && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```
git add apps/pendingcrew/Sources/Mac/Services/CrewSessionRunner.swift apps/pendingcrew/Sources/Mac/Views/AgentTerminalView.swift apps/pendingcrew/Sources/Mac/Views/CrewSessionWindowView.swift
git commit -m "pendingcrew: CrewSessionRun 持 SessionBackend(claude 经 terminalView 可选访问)"
```

---

## Phase 1 — JSON-RPC transport (pure Foundation, TDD, no codex needed)

### Task 1.1: `CodexRPCMessage` — envelope encode/decode + classification

**Files:**
- Create: `Sources/Mac/LocalRunner/CodexAppServer/CodexRPCMessage.swift`
- Create: `Tests/PendingCrewTests/CodexRPCMessageTests.swift`
- Modify: `apps/pendingcrew/project.yml` (add `CodexRPCMessage.swift` to PendingCrewTests sources), then `xcodegen`

- [ ] **Step 1: Write the failing test**

```swift
// CodexRPCMessageTests.swift
import XCTest
@testable import PendingCrew

final class CodexRPCMessageTests: XCTestCase {
    func testEncodeRequestOmitsJsonrpcAndIsSingleLine() throws {
        let line = try CodexRPCMessage.encodeRequest(
            id: 10, method: "thread/start", params: ["model": "gpt-5.5"])
        XCTAssertFalse(line.contains("\n"), "newline-delimited: one line, no embedded newline")
        XCTAssertFalse(line.contains("jsonrpc"), "jsonrpc must be omitted on the wire")
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        XCTAssertEqual(obj["id"] as? Int, 10)
        XCTAssertEqual(obj["method"] as? String, "thread/start")
    }

    func testClassifyResponse() throws {
        let msg = try CodexRPCMessage.classify(line: #"{"id":10,"result":{"thread":{"id":"thr_1"}}}"#)
        guard case let .response(id, result, error) = msg else { return XCTFail("expected response") }
        XCTAssertEqual(id, 10); XCTAssertNil(error); XCTAssertNotNil(result)
    }

    func testClassifyServerRequest() throws {
        let msg = try CodexRPCMessage.classify(
            line: #"{"id":0,"method":"item/commandExecution/requestApproval","params":{}}"#)
        guard case let .serverRequest(id, method, _) = msg else { return XCTFail("expected serverRequest") }
        XCTAssertEqual(id, 0)
        XCTAssertEqual(method, "item/commandExecution/requestApproval")
    }

    func testClassifyNotification() throws {
        let msg = try CodexRPCMessage.classify(line: #"{"method":"turn/started","params":{}}"#)
        guard case let .notification(method, _) = msg else { return XCTFail("expected notification") }
        XCTAssertEqual(method, "turn/started")
    }
}
```

- [ ] **Step 2: Add file to test target + regen + run test to verify it fails**

Add `Tests/PendingCrewTests/CodexRPCMessageTests.swift` and `Sources/Mac/LocalRunner/CodexAppServer/CodexRPCMessage.swift` to the `PendingCrewTests` `sources:` list in `apps/pendingcrew/project.yml`, then:
```
cd apps/pendingcrew && xcodegen && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' test -only-testing:PendingCrewTests/CodexRPCMessageTests
```
Expected: FAIL (CodexRPCMessage undefined). If the runner can't launch (PTY error), use the swiftc-driver fallback.

- [ ] **Step 3: Write minimal implementation**

```swift
// CodexRPCMessage.swift
#if os(macOS)
import Foundation

/// One incoming JSON-RPC line, classified by shape. `jsonrpc` is omitted on
/// the wire (codex app-server convention). Routing rule:
///   has `method` + `id`  → server-initiated request (we must reply)
///   has `method`, no `id`→ notification (streaming event)
///   has `id`, no `method`→ response to one of our requests
enum CodexRPCMessage {
    case response(id: Int, result: Any?, error: [String: Any]?)
    case serverRequest(id: Int, method: String, params: [String: Any])
    case notification(method: String, params: [String: Any])

    static func encodeRequest(id: Int, method: String, params: [String: Any]) throws -> String {
        try encode(["id": id, "method": method, "params": params])
    }
    static func encodeNotification(method: String, params: [String: Any]) throws -> String {
        try encode(["method": method, "params": params])
    }
    /// Reply to a server-initiated request (echo the server's id).
    static func encodeResponse(id: Int, result: [String: Any]) throws -> String {
        try encode(["id": id, "result": result])
    }

    private static func encode(_ obj: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)   // compact, single line
    }

    static func classify(line: String) throws -> CodexRPCMessage {
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] ?? [:]
        let method = obj["method"] as? String
        let id = obj["id"] as? Int
        let params = obj["params"] as? [String: Any] ?? [:]
        if let method, let id { return .serverRequest(id: id, method: method, params: params) }
        if let method { return .notification(method: method, params: params) }
        if let id { return .response(id: id, result: obj["result"], error: obj["error"] as? [String: Any]) }
        throw CodexRPCError.malformed(line)
    }
}

enum CodexRPCError: Error, Equatable { case malformed(String) }
#endif
```

- [ ] **Step 4: Run test to verify it passes**

```
cd apps/pendingcrew && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' test -only-testing:PendingCrewTests/CodexRPCMessageTests
```
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```
git add apps/pendingcrew/Sources/Mac/LocalRunner/CodexAppServer/CodexRPCMessage.swift apps/pendingcrew/Tests/PendingCrewTests/CodexRPCMessageTests.swift apps/pendingcrew/project.yml apps/pendingcrew/PendingCrew.xcodeproj
git commit -m "pendingcrew: codex JSON-RPC 帧编解码 + 分类(response/serverRequest/notification),TDD"
```

### Task 1.2: `CodexRPCDispatcher` — two-id-space router

**Files:**
- Create: `Sources/Mac/LocalRunner/CodexAppServer/CodexRPCDispatcher.swift`
- Create: `Tests/PendingCrewTests/CodexRPCDispatcherTests.swift`
- Modify: `apps/pendingcrew/project.yml` (+ both to test sources), `xcodegen`

- [ ] **Step 1: Write the failing test**

```swift
// CodexRPCDispatcherTests.swift
import XCTest
@testable import PendingCrew

final class CodexRPCDispatcherTests: XCTestCase {
    func testResponseResolvesOnlyMatchingClientId() async throws {
        let d = CodexRPCDispatcher()
        async let r: Any? = d.awaitResponse(id: 10)
        try await d.handle(.response(id: 10, result: ["ok": true], error: nil))
        let result = try await r as? [String: Any]
        XCTAssertEqual(result?["ok"] as? Bool, true)
    }

    func testServerRequestAndOurRequestCanShareIdZeroWithoutCollision() async throws {
        let d = CodexRPCDispatcher()
        var serverReqs: [(Int, String)] = []
        await d.setServerRequestHandler { id, method, _ in serverReqs.append((id, method)) }
        // our outstanding request id 0:
        async let ours: Any? = d.awaitResponse(id: 0)
        // server's own request, also id 0 — must NOT resolve our continuation:
        try await d.handle(.serverRequest(id: 0, method: "item/fileChange/requestApproval", params: [:]))
        XCTAssertEqual(serverReqs.count, 1)
        XCTAssertEqual(serverReqs.first?.0, 0)
        // now the real response to our id 0 arrives:
        try await d.handle(.response(id: 0, result: ["done": 1], error: nil))
        let result = try await ours as? [String: Any]
        XCTAssertEqual(result?["done"] as? Int, 1)
    }

    func testNotificationIsForwarded() async throws {
        let d = CodexRPCDispatcher()
        var notes: [String] = []
        await d.setNotificationHandler { method, _ in notes.append(method) }
        try await d.handle(.notification(method: "item/completed", params: [:]))
        XCTAssertEqual(notes, ["item/completed"])
    }

    func testErrorResponseThrows() async {
        let d = CodexRPCDispatcher()
        async let r: Any? = d.awaitResponse(id: 5)
        try? await d.handle(.response(id: 5, result: nil, error: ["message": "boom"]))
        do { _ = try await r; XCTFail("expected throw") } catch { /* ok */ }
    }
}
```

- [ ] **Step 2: Add files to test target + regen + verify FAIL**

Add both files to `project.yml` test sources, then `xcodegen`, then run `-only-testing:PendingCrewTests/CodexRPCDispatcherTests`. Expected: FAIL (undefined).

- [ ] **Step 3: Write minimal implementation**

```swift
// CodexRPCDispatcher.swift
#if os(macOS)
import Foundation

/// Routes classified messages. Keeps the two id spaces strictly separate:
/// `pending` (our outgoing requests awaiting a response, keyed by OUR id) vs
/// server-initiated requests (keyed by the SERVER's id) which never touch
/// `pending`. Both sides may use the same integer (e.g. id 0).
actor CodexRPCDispatcher {
    private var pending: [Int: CheckedContinuation<Any?, Error>] = [:]
    private var onServerRequest: ((Int, String, [String: Any]) -> Void)?
    private var onNotification: ((String, [String: Any]) -> Void)?

    func setServerRequestHandler(_ h: @escaping (Int, String, [String: Any]) -> Void) { onServerRequest = h }
    func setNotificationHandler(_ h: @escaping (String, [String: Any]) -> Void) { onNotification = h }

    /// Suspend until the response for OUR request `id` arrives.
    func awaitResponse(id: Int) async throws -> Any? {
        try await withCheckedThrowingContinuation { cont in pending[id] = cont }
    }

    func handle(_ msg: CodexRPCMessage) throws {
        switch msg {
        case let .response(id, result, error):
            guard let cont = pending.removeValue(forKey: id) else { return }   // unknown id → ignore
            if let error { cont.resume(throwing: CodexRPCError.server(error)) }
            else { cont.resume(returning: result) }
        case let .serverRequest(id, method, params):
            onServerRequest?(id, method, params)
        case let .notification(method, params):
            onNotification?(method, params)
        }
    }

    /// Fail all outstanding requests (process died / connection closed).
    func failAll(_ error: Error) {
        for (_, cont) in pending { cont.resume(throwing: error) }
        pending.removeAll()
    }
}

extension CodexRPCError { static func server(_ payload: [String: Any]) -> CodexRPCError {
    .malformed("server error: \(payload["message"] as? String ?? "unknown")") } }
#endif
```

- [ ] **Step 4: Run test to verify PASS**

`xcodebuild ... test -only-testing:PendingCrewTests/CodexRPCDispatcherTests` → PASS (4 tests).

- [ ] **Step 5: Commit**

```
git add apps/pendingcrew/Sources/Mac/LocalRunner/CodexAppServer/CodexRPCDispatcher.swift apps/pendingcrew/Tests/PendingCrewTests/CodexRPCDispatcherTests.swift apps/pendingcrew/project.yml apps/pendingcrew/PendingCrew.xcodeproj
git commit -m "pendingcrew: codex RPC dispatcher — 双 id 空间路由(TDD,坐实 id0 不撞)"
```

---

## Phase 2 — protocol models + transcript (pure Foundation, TDD)

> **Field-name caveat:** the exact JSON field names for `ThreadItem` arms are version-locked. The structs below follow the documented shapes in the reference spec. The implementer should capture a real fixture once on the user's machine via `codex app-server generate-json-schema --out ./codex-proto-schema --experimental` (or a captured live `item/completed` line) and reconcile field names BEFORE the real-machine tail. Keep `.unknown` so unmatched arms degrade instead of crashing.

### Task 2.1: `CodexThreadItem` — union decode with `.unknown` fallthrough

**Files:**
- Create: `Sources/Mac/LocalRunner/CodexAppServer/CodexThreadItem.swift`
- Create: `Tests/PendingCrewTests/CodexThreadItemTests.swift`
- Create: `Tests/PendingCrewTests/Fixtures/codex-items/*.json` (one per arm)
- Modify: `project.yml` test sources, `xcodegen`

- [ ] **Step 1: Write the failing test (with fixtures)**

Create fixtures, e.g. `agentMessage.json`:
```json
{ "id": "item_1", "type": "agentMessage", "text": "Done.", "phase": "final" }
```
`commandExecution.json`:
```json
{ "id": "item_2", "type": "commandExecution", "command": "ls -la",
  "cwd": "/repo", "status": "completed", "aggregatedOutput": "a\nb", "exitCode": 0 }
```
`unknownArm.json`:
```json
{ "id": "item_9", "type": "someFutureType", "blob": 42 }
```

```swift
// CodexThreadItemTests.swift
import XCTest
@testable import PendingCrew

final class CodexThreadItemTests: XCTestCase {
    private func load(_ name: String) throws -> CodexThreadItem {
        let url = Bundle.module.url(forResource: name, withExtension: "json",
                                    subdirectory: "Fixtures/codex-items")!
        return try JSONDecoder().decode(CodexThreadItem.self, from: Data(contentsOf: url))
    }
    func testDecodeAgentMessage() throws {
        guard case let .agentMessage(text, _) = try load("agentMessage").kind else {
            return XCTFail("expected agentMessage") }
        XCTAssertEqual(text, "Done.")
    }
    func testDecodeCommandExecution() throws {
        guard case let .commandExecution(cmd) = try load("commandExecution").kind else {
            return XCTFail("expected commandExecution") }
        XCTAssertEqual(cmd.command, "ls -la"); XCTAssertEqual(cmd.exitCode, 0)
    }
    func testUnknownArmDegradesNotCrashes() throws {
        guard case .unknown = try load("unknownArm").kind else { return XCTFail("expected unknown") }
    }
}
```

> Note: `Bundle.module` requires the test target to bundle the fixtures dir as a resource. If the xcodeproj test target doesn't support `Bundle.module`, load via a path relative to `#file` instead (see existing fixture-loading tests for the project's convention — check `Tests/PendingCrewTests/Fixtures` usage).

- [ ] **Step 2: Add files + fixtures to test target, regen, verify FAIL.**

- [ ] **Step 3: Write minimal implementation**

```swift
// CodexThreadItem.swift
#if os(macOS)
import Foundation

/// A codex `ThreadItem` reduced to what the transcript renders. `.unknown`
/// keeps forward-compat: a codex upgrade adding a new arm degrades to a raw
/// row instead of failing the decode.
struct CodexThreadItem: Decodable, Identifiable, Equatable {
    let id: String
    let kind: Kind

    enum Kind: Equatable {
        case userMessage(text: String)
        case agentMessage(text: String, phase: String?)
        case reasoning(summary: String?, content: String?)
        case plan(text: String)
        case commandExecution(CommandExec)
        case fileChange(FileChange)
        case toolCall(name: String, status: String?)        // mcp/dynamic/collab folded
        case webSearch(query: String?)
        case unknown(type: String)
    }
    struct CommandExec: Equatable {
        let command: String; let cwd: String?; let status: String?
        let aggregatedOutput: String?; let exitCode: Int?
    }
    struct FileChange: Equatable { let status: String?; let summary: String? }

    private enum Keys: String, CodingKey {
        case id, type, text, phase, summary, content, command, cwd, status
        case aggregatedOutput, exitCode, name, query, changes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        let type = (try? c.decode(String.self, forKey: .type)) ?? "unknown"
        func s(_ k: Keys) -> String? { try? c.decode(String.self, forKey: k) }
        switch type {
        case "userMessage":  kind = .userMessage(text: s(.text) ?? "")
        case "agentMessage": kind = .agentMessage(text: s(.text) ?? "", phase: s(.phase))
        case "reasoning":    kind = .reasoning(summary: s(.summary), content: s(.content))
        case "plan":         kind = .plan(text: s(.text) ?? "")
        case "commandExecution":
            kind = .commandExecution(.init(command: s(.command) ?? "", cwd: s(.cwd),
                status: s(.status), aggregatedOutput: s(.aggregatedOutput),
                exitCode: try? c.decode(Int.self, forKey: .exitCode)))
        case "fileChange":   kind = .fileChange(.init(status: s(.status), summary: s(.summary)))
        case "mcpToolCall", "dynamicToolCall", "collabAgentToolCall":
            kind = .toolCall(name: s(.name) ?? type, status: s(.status))
        case "webSearch":    kind = .webSearch(query: s(.query))
        default:             kind = .unknown(type: type)
        }
    }
}
#endif
```

- [ ] **Step 4: Run test → PASS (3 tests).**
- [ ] **Step 5: Commit**

```
git add apps/pendingcrew/Sources/Mac/LocalRunner/CodexAppServer/CodexThreadItem.swift apps/pendingcrew/Tests/PendingCrewTests/CodexThreadItemTests.swift apps/pendingcrew/Tests/PendingCrewTests/Fixtures/codex-items apps/pendingcrew/project.yml apps/pendingcrew/PendingCrew.xcodeproj
git commit -m "pendingcrew: CodexThreadItem union 解码 + .unknown 兜底(TDD,fixtures)"
```

### Task 2.2: `CodexTranscript` — observable state machine

**Files:**
- Create: `Sources/Mac/LocalRunner/CodexAppServer/CodexTranscript.swift`
- Create: `Tests/PendingCrewTests/CodexTranscriptTests.swift`
- Modify: `project.yml` test sources, `xcodegen`

- [ ] **Step 1: Write the failing test**

```swift
// CodexTranscriptTests.swift
import XCTest
@testable import PendingCrew

@MainActor
final class CodexTranscriptTests: XCTestCase {
    func testItemCompletedAppendsAndUpsertsById() {
        let t = CodexTranscript()
        t.apply(method: "item/completed",
                params: ["item": ["id": "i1", "type": "agentMessage", "text": "hi"]])
        XCTAssertEqual(t.items.count, 1)
        // same id again = upsert (authoritative final), not duplicate
        t.apply(method: "item/completed",
                params: ["item": ["id": "i1", "type": "agentMessage", "text": "hi (final)"]])
        XCTAssertEqual(t.items.count, 1)
        guard case let .agentMessage(text, _) = t.items[0].kind else { return XCTFail() }
        XCTAssertEqual(text, "hi (final)")
    }
    func testTurnLifecycleTogglesActive() {
        let t = CodexTranscript()
        t.apply(method: "turn/started", params: ["turn": ["id": "t1"]])
        XCTAssertTrue(t.turnActive); XCTAssertEqual(t.activeTurnId, "t1")
        t.apply(method: "turn/completed", params: ["turn": ["id": "t1"], "status": "completed"])
        XCTAssertFalse(t.turnActive)
    }
}
```

- [ ] **Step 2: Add files, regen, verify FAIL.**

- [ ] **Step 3: Write minimal implementation**

```swift
// CodexTranscript.swift
#if os(macOS)
import Foundation

/// Observable transcript built from codex streaming notifications. v1 renders on
/// `item/completed` (authoritative final per item); deltas are opted out.
@MainActor
final class CodexTranscript: ObservableObject {
    @Published private(set) var items: [CodexThreadItem] = []
    @Published private(set) var turnActive = false
    @Published private(set) var activeTurnId: String?

    func apply(method: String, params: [String: Any]) {
        switch method {
        case "turn/started":
            activeTurnId = (params["turn"] as? [String: Any])?["id"] as? String
            turnActive = true
        case "turn/completed":
            turnActive = false; activeTurnId = nil
        case "item/completed":
            guard let itemObj = params["item"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: itemObj),
                  let item = try? JSONDecoder().decode(CodexThreadItem.self, from: data) else { return }
            if let idx = items.firstIndex(where: { $0.id == item.id }) { items[idx] = item }
            else { items.append(item) }
        default:
            break   // item/started, deltas, token usage — ignored in v1
        }
    }
}
#endif
```

- [ ] **Step 4: Run test → PASS (2 tests).**
- [ ] **Step 5: Commit**

```
git add apps/pendingcrew/Sources/Mac/LocalRunner/CodexAppServer/CodexTranscript.swift apps/pendingcrew/Tests/PendingCrewTests/CodexTranscriptTests.swift apps/pendingcrew/project.yml apps/pendingcrew/PendingCrew.xcodeproj
git commit -m "pendingcrew: CodexTranscript 状态机(item/completed upsert + turn 生命周期),TDD"
```

### Task 2.3: `CodexProtocol` — request/notification builders for the core subset

**Files:**
- Create: `Sources/Mac/LocalRunner/CodexAppServer/CodexProtocol.swift`
- Create: `Tests/PendingCrewTests/CodexProtocolTests.swift`
- Modify: `project.yml` test sources, `xcodegen`

- [ ] **Step 1: Write the failing test**

```swift
// CodexProtocolTests.swift
import XCTest
@testable import PendingCrew

final class CodexProtocolTests: XCTestCase {
    func testInitializeParamsCarryClientInfo() {
        let p = CodexProtocol.initializeParams(clientName: "PendingCrew", version: "1.0")
        let info = p["clientInfo"] as? [String: Any]
        XCTAssertEqual(info?["name"] as? String, "PendingCrew")
        XCTAssertEqual((p["capabilities"] as? [String: Any])?["experimentalApi"] as? Bool, true)
    }
    func testThreadStartCarriesCwdAndDeveloperInstructionsAndApprovalPolicy() {
        let p = CodexProtocol.threadStartParams(
            cwd: "/repo", model: "gpt-5.5", developerInstructions: "world-model",
            mcpServers: ["crew": ["command": "/bin/helper", "args": ["--mcp-serve"]]])
        XCTAssertEqual(p["cwd"] as? String, "/repo")
        XCTAssertEqual(p["developerInstructions"] as? String, "world-model")
        XCTAssertEqual(p["approvalPolicy"] as? String, "on-request")
        XCTAssertEqual(p["sandbox"] as? String, "workspace-write")
        XCTAssertEqual(p["approvalsReviewer"] as? String, "user")
        XCTAssertNotNil(p["mcpServers"])
    }
    func testTurnStartWrapsTextAndUntrustedWhiteboard() {
        let p = CodexProtocol.turnStartParams(threadId: "thr_1", text: "go", whiteboard: "unread:1")
        let input = p["input"] as? [[String: Any]]
        XCTAssertEqual(input?.first?["type"] as? String, "text")
        XCTAssertEqual(input?.first?["text"] as? String, "go")
        let wb = (p["additionalContext"] as? [String: Any])?["whiteboard"] as? [String: Any]
        XCTAssertEqual(wb?["kind"] as? String, "untrusted")
        XCTAssertEqual(wb?["value"] as? String, "unread:1")
    }
    func testTurnStartOmitsWhiteboardWhenEmpty() {
        let p = CodexProtocol.turnStartParams(threadId: "thr_1", text: "go", whiteboard: nil)
        XCTAssertNil(p["additionalContext"])
    }
}
```

- [ ] **Step 2: Add files, regen, verify FAIL.**

- [ ] **Step 3: Write minimal implementation**

```swift
// CodexProtocol.swift
#if os(macOS)
import Foundation

/// Param builders for the core-loop methods. Plain dictionaries (paired with
/// CodexRPCMessage encoding) keep this Foundation-only + unit-testable.
enum CodexProtocol {
    static func initializeParams(clientName: String, version: String) -> [String: Any] {
        ["clientInfo": ["name": clientName, "title": clientName, "version": version],
         "capabilities": ["experimentalApi": true]]
    }

    static func threadStartParams(cwd: String, model: String?, developerInstructions: String?,
                                  mcpServers: [String: Any]?) -> [String: Any] {
        var p: [String: Any] = [
            "cwd": cwd,
            "approvalPolicy": "on-request",
            "sandbox": "workspace-write",
            "approvalsReviewer": "user",
        ]
        if let model, !model.isEmpty { p["model"] = model }
        if let di = developerInstructions, !di.isEmpty { p["developerInstructions"] = di }
        if let mcp = mcpServers, !mcp.isEmpty { p["mcpServers"] = mcp }
        return p
    }

    static func turnStartParams(threadId: String, text: String, whiteboard: String?) -> [String: Any] {
        var p: [String: Any] = [
            "threadId": threadId,
            "input": [["type": "text", "text": text, "text_elements": []]],
        ]
        if let wb = whiteboard, !wb.isEmpty {
            p["additionalContext"] = ["whiteboard": ["value": wb, "kind": "untrusted"]]
        }
        return p
    }

    static func turnInterruptParams(threadId: String, turnId: String) -> [String: Any] {
        ["threadId": threadId, "turnId": turnId]
    }
}
#endif
```

- [ ] **Step 4: Run test → PASS (4 tests).**
- [ ] **Step 5: Commit**

```
git add apps/pendingcrew/Sources/Mac/LocalRunner/CodexAppServer/CodexProtocol.swift apps/pendingcrew/Tests/PendingCrewTests/CodexProtocolTests.swift apps/pendingcrew/project.yml apps/pendingcrew/PendingCrew.xcodeproj
git commit -m "pendingcrew: codex 协议 param builders(initialize/thread.start/turn.start),TDD"
```

---

## Phase 3 — SessionConfig + env guard + connection + backend

### Task 3.1: SessionConfig codex branch → app-server spawn argv

**Files:**
- Modify: `Sources/Mac/LocalRunner/SessionConfig.swift`
- Modify: `Tests/PendingCrewTests/SessionConfigTests.swift`

- [ ] **Step 1: Update the failing tests**

Replace the three codex placeholder tests (`testCodexArgvUnchangedPlaceholder`, `testCodexIgnoresAppendSystemPromptFile`, `testCodexIgnoresSettingsAndMcpConfig`) with:
```swift
func testCodexArgvIsAppServerWithEffortOverride() {
    let cfg = SessionConfig(kind: .codex, effort: "high", initialPrompt: "ship it")
    // codex now launches app-server; effort is deterministic via -c on spawn (spec §5).
    // initialPrompt is NOT argv for codex — it's sent as the first turn after handshake.
    XCTAssertEqual(cfg.argv(), ["-c", "model_reasoning_effort=high", "app-server"])
}
func testCodexArgvAppServerNoEffort() {
    let cfg = SessionConfig(kind: .codex, initialPrompt: "go")
    XCTAssertEqual(cfg.argv(), ["app-server"])
}
func testCodexArgvIgnoresClaudeOnlyFlags() {
    let cfg = SessionConfig(kind: .codex, initialPrompt: "go",
                            appendSystemPromptFile: "/t/w.md",
                            settingsFile: "/t/s.json", mcpConfigFile: "/t/m.json")
    XCTAssertEqual(cfg.argv(), ["app-server"])
}
```

- [ ] **Step 2: Run tests → verify FAIL (still placeholder argv).**

- [ ] **Step 3: Rewrite the codex branch in `SessionConfig.argv()`**

```swift
case .codex:
    // codex runs as an app-server (stdio JSON-RPC), NOT an interactive TUI.
    // effort goes via `-c model_reasoning_effort=<e>` on spawn — config.toml
    // overrides turn-level effort, so -c is the deterministic path (spec §5).
    // model / cwd / developerInstructions / initialPrompt are NOT argv —
    // they go over the protocol (thread/start, turn/start) after the handshake.
    var a: [String] = []
    if let e = effort, !e.isEmpty { a += ["-c", "model_reasoning_effort=\(e)"] }
    a.append("app-server")
    return a
```

- [ ] **Step 4: Run tests → PASS. Build.**

```
cd apps/pendingcrew && xcodebuild ... test -only-testing:PendingCrewTests/SessionConfigTests
```

- [ ] **Step 5: Commit**

```
git add apps/pendingcrew/Sources/Mac/LocalRunner/SessionConfig.swift apps/pendingcrew/Tests/PendingCrewTests/SessionConfigTests.swift
git commit -m "pendingcrew: SessionConfig codex 分支 → app-server argv + effort -c override(去占位)"
```

### Task 3.2: env billing guard — omit `OPENAI_API_KEY` for codex

**Files:**
- Modify: `Sources/Mac/LocalRunner/LocalCodingAgentSpec.swift` (`LocalCodingAgentEnv`)
- Create/Modify: `Tests/PendingCrewTests/LocalCodingAgentTests.swift` (add a case)

- [ ] **Step 1: Write the failing test**

```swift
func testCodexEnvOmitsOpenAIApiKeySoSubscriptionBillingStays() {
    // An exported OPENAI_API_KEY would flip app-server to pay-as-you-go despite
    // a chatgpt auth.json. Guard: codex env must never carry it.
    let env = LocalCodingAgentEnv.build(additionalEnv: ["OPENAI_API_KEY": "sk-xxx"], kind: .codex)
    XCTAssertNil(env["OPENAI_API_KEY"])
}
func testClaudeEnvStillAllowsCallerKeys() {
    let env = LocalCodingAgentEnv.build(additionalEnv: ["ANTHROPIC_API_KEY": "x"], kind: .claudeCode)
    XCTAssertEqual(env["ANTHROPIC_API_KEY"], "x")
}
```

- [ ] **Step 2: Run → FAIL (build returns no `kind:` param yet).**

- [ ] **Step 3: Add the `kind:` param + guard**

In `LocalCodingAgentEnv.build`, add a `kind: LocalCodingAgentKind` parameter (default `.claudeCode` to keep claude call sites compiling). After building the env dict, strip the key for codex:
```swift
static func build(additionalEnv: [String: String] = [:],
                  kind: LocalCodingAgentKind = .claudeCode) -> [String: String] {
    var env = /* existing whitelist + additionalEnv merge */
    if kind == .codex { env.removeValue(forKey: "OPENAI_API_KEY") }
    return env
}
```
Update `CrewSessionRunner.start()` to pass `kind: config.kind`.

- [ ] **Step 4: Run → PASS. Build.**

- [ ] **Step 5: Commit**

```
git add apps/pendingcrew/Sources/Mac/LocalRunner/LocalCodingAgentSpec.swift apps/pendingcrew/Tests/PendingCrewTests/LocalCodingAgentTests.swift apps/pendingcrew/Sources/Mac/Services/CrewSessionRunner.swift
git commit -m "pendingcrew: codex env 守卫 — 剥 OPENAI_API_KEY(订阅计费不被翻成按量),TDD"
```

### Task 3.3: `CodexAppServerConnection` — actor wiring process pipes to codec+dispatcher

**Files:**
- Create: `Sources/Mac/LocalRunner/CodexAppServer/CodexAppServerConnection.swift` (app target only — spawns Process)

- [ ] **Step 1: Implement (no unit test — integration-only; logic lives in tested codec/dispatcher)**

```swift
// CodexAppServerConnection.swift
#if os(macOS)
import Foundation

/// Owns the `codex app-server` child process and its stdio pipes. Encodes our
/// requests with CodexRPCMessage, routes incoming lines through CodexRPCDispatcher.
/// The hard logic (framing, two-id routing) is unit-tested in the codec/dispatcher;
/// this type is the thin Process/pipe wrapper, verified on the real machine.
actor CodexAppServerConnection {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let dispatcher = CodexRPCDispatcher()
    private var nextId = 0
    private var readBuffer = Data()

    init(executable: String, argv: [String], cwd: String, env: [String: String]) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = argv                 // SessionConfig.argv() → ["app-server"] (+ -c …)
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = env                 // env guard already stripped OPENAI_API_KEY
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
    }

    func start(onServerRequest: @escaping (Int, String, [String: Any]) -> Void,
               onNotification: @escaping (String, [String: Any]) -> Void) async throws {
        await dispatcher.setServerRequestHandler(onServerRequest)
        await dispatcher.setNotificationHandler(onNotification)
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            Task { await self?.ingest(data) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { await self?.handleTermination() }
        }
        try process.run()
        // initialize handshake
        _ = try await request(method: "initialize",
                              params: CodexProtocol.initializeParams(clientName: "PendingCrew", version: "1.0"))
        try notify(method: "initialized", params: [:])
    }

    private func ingest(_ data: Data) async {
        readBuffer.append(data)
        while let nl = readBuffer.firstIndex(of: 0x0a) {
            let lineData = readBuffer[..<nl]
            readBuffer.removeSubrange(...nl)
            guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
            if let msg = try? CodexRPCMessage.classify(line: line) { try? await dispatcher.handle(msg) }
        }
    }

    /// Send a request and await its response (our client id space).
    @discardableResult
    func request(method: String, params: [String: Any]) async throws -> Any? {
        let id = nextId; nextId += 1
        async let response: Any? = dispatcher.awaitResponse(id: id)
        try writeLine(CodexRPCMessage.encodeRequest(id: id, method: method, params: params))
        return try await response
    }
    func notify(method: String, params: [String: Any]) throws {
        try writeLine(CodexRPCMessage.encodeNotification(method: method, params: params))
    }
    /// Reply to a server-initiated request (echo the server's id).
    func respond(serverId: Int, result: [String: Any]) throws {
        try writeLine(CodexRPCMessage.encodeResponse(id: serverId, result: result))
    }

    private func writeLine(_ line: String) throws {
        stdinPipe.fileHandleForWriting.write(Data((line + "\n").utf8))
    }
    private func handleTermination() async {
        await dispatcher.failAll(CodexRPCError.malformed("app-server terminated"))
    }
    func terminate() {
        if process.isRunning { process.terminate() }
        let pid = process.processIdentifier
        Task { await terminateTree(pid: pid, graceSeconds: 2.0) }   // reuse existing helper
    }
    var isRunning: Bool { process.isRunning }
}
#endif
```

- [ ] **Step 2: Build**

```
cd apps/pendingcrew && xcodegen && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' build
```
(Add the file to the `PendingCrew` app target only — NOT the test target.)

- [ ] **Step 3: Commit**

```
git add apps/pendingcrew/Sources/Mac/LocalRunner/CodexAppServer/CodexAppServerConnection.swift apps/pendingcrew/project.yml apps/pendingcrew/PendingCrew.xcodeproj
git commit -m "pendingcrew: CodexAppServerConnection — spawn codex app-server + stdio JSON-RPC 接线 + initialize 握手"
```

### Task 3.4: `CodexAppServerBackend` — SessionBackend impl

**Files:**
- Create: `Sources/Mac/LocalRunner/CodexAppServer/CodexAppServerBackend.swift` (app target)

- [ ] **Step 1: Implement**

```swift
// CodexAppServerBackend.swift
#if os(macOS)
import Foundation
import Combine

/// codex session over app-server. Conforms to SessionBackend so CrewSessionRun
/// treats it like the terminal backend. Output goes to `transcript` (rendered by
/// CodexTranscriptView). `send` runs a turn; `interrupt` cancels it; `stop` ends
/// the process. Approvals + per-turn whiteboard are injected via the providers.
@MainActor
final class CodexAppServerBackend: ObservableObject, SessionBackend {
    let kind: LocalCodingAgentKind = .codex
    let transcript = CodexTranscript()
    @Published private(set) var status: SessionStatus = .running
    var statusPublisher: Published<SessionStatus>.Publisher { $status }

    private let connection: CodexAppServerConnection
    private let cwd: String
    private let model: String?
    private let developerInstructions: String?
    private let mcpServers: [String: Any]?
    /// Pulls the unread-whiteboard string to inject as additionalContext each turn.
    private let whiteboardProvider: () -> String?
    /// Routes a codex approval request into the existing approval UI; returns the
    /// decision string ("accept"/"decline"/…) when the human answers.
    private let approvalProvider: (_ summary: String, _ decisions: [String]) async -> String

    private var threadId: String?
    private var activeTurnId: String?

    init(executable: String, argv: [String], cwd: String, env: [String: String],
         model: String?, developerInstructions: String?, mcpServers: [String: Any]?,
         whiteboardProvider: @escaping () -> String?,
         approvalProvider: @escaping (_ summary: String, _ decisions: [String]) async -> String) {
        self.connection = CodexAppServerConnection(executable: executable, argv: argv, cwd: cwd, env: env)
        self.cwd = cwd; self.model = model
        self.developerInstructions = developerInstructions; self.mcpServers = mcpServers
        self.whiteboardProvider = whiteboardProvider; self.approvalProvider = approvalProvider
    }

    /// Boot: handshake → thread/start → (caller sends first turn via send()).
    func boot(initialPrompt: String?) {
        Task {
            do {
                try await connection.start(
                    onServerRequest: { [weak self] id, method, params in
                        Task { await self?.handleServerRequest(id: id, method: method, params: params) }
                    },
                    onNotification: { [weak self] method, params in
                        Task { @MainActor in self?.transcript.apply(method: method, params: params)
                            self?.trackTurn(method: method, params: params) }
                    })
                let result = try await connection.request(
                    method: "thread/start",
                    params: CodexProtocol.threadStartParams(
                        cwd: cwd, model: model, developerInstructions: developerInstructions,
                        mcpServers: mcpServers)) as? [String: Any]
                self.threadId = (result?["thread"] as? [String: Any])?["id"] as? String
                if let p = initialPrompt, !p.isEmpty { self.send(p) }
            } catch {
                self.status = .exited(1)
            }
        }
    }

    func send(_ text: String) {
        guard let threadId else { return }
        let wb = whiteboardProvider()
        Task {
            _ = try? await connection.request(
                method: "turn/start",
                params: CodexProtocol.turnStartParams(threadId: threadId, text: text, whiteboard: wb))
        }
    }
    func interrupt() {
        guard let threadId, let turnId = activeTurnId else { return }
        Task { try? await connection.request(method: "turn/interrupt",
            params: CodexProtocol.turnInterruptParams(threadId: threadId, turnId: turnId)) }
    }
    func stop() {
        guard status == .running else { return }
        status = .exited(nil)
        Task { await connection.terminate() }
    }

    private func trackTurn(method: String, params: [String: Any]) {
        if method == "turn/started" { activeTurnId = (params["turn"] as? [String: Any])?["id"] as? String }
        if method == "turn/completed" { activeTurnId = nil }
    }

    private func handleServerRequest(id: Int, method: String, params: [String: Any]) async {
        guard method.hasSuffix("requestApproval") else { return }
        let summary = (params["command"] as? String) ?? (params["reason"] as? String) ?? method
        let decisions = (params["availableDecisions"] as? [String]) ?? ["accept", "decline"]
        let decision = await approvalProvider(summary, decisions)
        try? await connection.respond(serverId: id, result: ["decision": decision])
    }
}
#endif
```

- [ ] **Step 2: Build**

```
cd apps/pendingcrew && xcodegen && xcodebuild ... build
```

- [ ] **Step 3: Commit**

```
git add apps/pendingcrew/Sources/Mac/LocalRunner/CodexAppServer/CodexAppServerBackend.swift apps/pendingcrew/project.yml apps/pendingcrew/PendingCrew.xcodeproj
git commit -m "pendingcrew: CodexAppServerBackend(SessionBackend impl) — thread/turn + 审批桥 + 白板 additionalContext"
```

---

## Phase 4 — wire codex into the launch path

### Task 4.1: `CrewSessionRunner.start()` picks the backend by kind

**Files:**
- Modify: `Sources/Mac/Services/CrewSessionRunner.swift`
- Modify: `Sources/Mac/LocalRunner/LocalSessionLaunch.swift` (codex helpers)

- [ ] **Step 1: Add codex launch params to `start()`**

`start()` currently builds `AgentTerminalSession` unconditionally. Branch by `config.kind`:
- `.claudeCode` → existing `AgentTerminalSession(...)` path (uses `config.appendSystemPromptFile`/`settingsFile`/`mcpConfigFile`).
- `.codex` → build a `CodexAppServerBackend(...)`:
  - `argv = config.argv()` (→ `["app-server"]` + effort `-c`)
  - `developerInstructions` = the rendered world-model **string** (see Step 2) — NOT a file.
  - `mcpServers` = the codex MCP config dict (see Step 3).
  - `whiteboardProvider` = `{ LocalWhiteboardStore(...).unreadText(crewId:sessionId:) }` (add a small unread→string helper to LocalWhiteboardStore if absent).
  - `approvalProvider` = closure that raises a permission entry in `LocalApprovalStore` and long-polls for the decision (mirror `McpPermissionHook`'s wait, but in-process; returns the decision string).
  - call `backend.boot(initialPrompt: config.initialPrompt)`.

Pass `backend` into `CrewSessionRun(backend:...)`.

- [ ] **Step 2: Add codex world-model + MCP helpers to `LocalSessionLaunch`**

```swift
/// codex variant: world-model as a STRING (→ thread/start.developerInstructions),
/// not a temp file. Same renderer as claude.
static func renderWorldModelString(detail: CrewDetail, members: [CrewMember],
    taskBrief: String, workdir: URL, sessionId: String, appendPersona: String? = nil) -> String? {
    // identical Context build to renderWorldModelFile, return the rendered md string
    // (don't write a file).
}

/// codex MCP config dict for thread/start.mcpServers — same crew helper as claude.
static func codexMcpServers(crewId: String, sessionId: String, captain: Bool = false) -> [String: Any]? {
    guard let helper = Bundle.main.executablePath else { return nil }
    let dir = LocalWhiteboardStore.defaultDirectory.path
    var args = ["--mcp-serve", "--crew", crewId, "--dir", dir, "--session", sessionId]
    if captain { args.append("--captain") }
    return ["crew": ["command": helper, "args": args]]
}
```

- [ ] **Step 3: Build**

```
cd apps/pendingcrew && xcodebuild ... build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```
git add apps/pendingcrew/Sources/Mac/Services/CrewSessionRunner.swift apps/pendingcrew/Sources/Mac/LocalRunner/LocalSessionLaunch.swift
git commit -m "pendingcrew: runner 按 kind 选 backend — codex 走 CodexAppServerBackend(世界观=developerInstructions,MCP/白板/审批接线)"
```

### Task 4.2: Update the launch call sites (codex doesn't set claude flags)

**Files:**
- Modify: `Sources/Mac/Views/CrewSessionWindowView.swift` (3 start sites), `Sources/Mac/Services/CrewRelayAgent.swift` (1 site)

- [ ] **Step 1: Branch the per-kind config prep at each call site**

Where the caller currently sets `config.appendSystemPromptFile` / `settingsFile` / `mcpConfigFile` from `LocalSessionLaunch.renderWorldModelFile` + `prepareLocalCommsConfig` (claude path), gate on kind: for codex, skip those (the runner's codex branch handles developerInstructions/mcpServers/whiteboard internally). Simplest: pass the raw inputs (detail/members/taskBrief/captain) into `start()` so the runner builds the right thing per kind — OR keep claude prep at the call site and have codex prep happen in the runner. Choose the runner-internal approach to avoid duplicating the branch across 4 sites: pass `detail`, `members`, `captain` to `start()` and let it call the right `LocalSessionLaunch` helper per kind.

- [ ] **Step 2: Build**

```
cd apps/pendingcrew && xcodebuild ... build
```

- [ ] **Step 3: Commit**

```
git add apps/pendingcrew/Sources/Mac/Views/CrewSessionWindowView.swift apps/pendingcrew/Sources/Mac/Services/CrewRelayAgent.swift
git commit -m "pendingcrew: 起 session 调用点按 kind 分流(codex 不设 claude flag,comms 接线归 runner)"
```

---

## Phase 5 — structured transcript view

### Task 5.1: `CodexTranscriptView` — per-arm SwiftUI rendering

**Files:**
- Create: `Sources/Mac/Views/CodexTranscriptView.swift` (app target)

- [ ] **Step 1: Implement (UX model: codex desktop)**

```swift
// CodexTranscriptView.swift
#if os(macOS)
import SwiftUI

/// Structured transcript for a codex app-server session. One row per ThreadItem
/// arm. Uses Theme tokens (dark-mode aware). UX modeled on the codex desktop client.
struct CodexTranscriptView: View {
    @ObservedObject var transcript: CodexTranscript
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(transcript.items) { item in row(item).id(item.id) }
                    if transcript.turnActive { ProgressView().padding(.vertical, 6) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .onChange(of: transcript.items.count) { _, _ in
                if let last = transcript.items.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    @ViewBuilder private func row(_ item: CodexThreadItem) -> some View {
        switch item.kind {
        case let .userMessage(text):        bubble(text, role: "你", tint: Theme.Palette.accent)
        case let .agentMessage(text, _):    bubble(text, role: "Codex", tint: Theme.Palette.surface)
        case let .reasoning(summary, content):
            DisclosureGroup("思考") { Text(content ?? summary ?? "").font(.callout).textSelection(.enabled) }
        case let .plan(text):               labeled("计划", text)
        case let .commandExecution(c):      commandCard(c)
        case let .fileChange(f):            labeled("文件改动", f.summary ?? (f.status ?? ""))
        case let .toolCall(name, status):   labeled("工具", name + (status.map { " · \($0)" } ?? ""))
        case let .webSearch(query):         labeled("搜索", query ?? "")
        case let .unknown(type):            labeled("(\(type))", "")   // forward-compat degrade
        }
    }

    private func bubble(_ text: String, role: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(role).font(.caption2).foregroundStyle(.secondary)
            Text(text).textSelection(.enabled)
        }.padding(8).background(tint.opacity(0.15)).clipShape(RoundedRectangle(cornerRadius: 8))
    }
    private func labeled(_ label: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            if !body.isEmpty { Text(body).font(.callout).textSelection(.enabled) }
        }
    }
    private func commandCard(_ c: CodexThreadItem.CommandExec) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Image(systemName: "terminal"); Text(c.command).font(.system(.callout, design: .monospaced)) }
            if let out = c.aggregatedOutput, !out.isEmpty {
                Text(out).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(12).textSelection(.enabled)
            }
            if let code = c.exitCode { Text("exit \(code)").font(.caption2)
                .foregroundStyle(code == 0 ? .green : .red) }
        }.padding(8).background(Theme.Palette.surface.opacity(0.2))
         .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
#endif
```

> Verify `Theme.Palette` token names against the existing `Theme.swift` (the dark-mode work defined the palette). Adjust token names if they differ.

- [ ] **Step 2: Build**

```
cd apps/pendingcrew && xcodegen && xcodebuild ... build
```

- [ ] **Step 3: Commit**

```
git add apps/pendingcrew/Sources/Mac/Views/CodexTranscriptView.swift apps/pendingcrew/project.yml apps/pendingcrew/PendingCrew.xcodeproj
git commit -m "pendingcrew: CodexTranscriptView — 结构化 transcript 逐 arm 渲染(对标 codex desktop)"
```

### Task 5.2: Inspector branches the session view by kind

**Files:**
- Modify: `Sources/Mac/Views/CrewSessionWindowView.swift`

- [ ] **Step 1: Branch the run's content view**

Where the run is rendered (currently embeds `AgentTerminalView(session:)` via `run.terminalView`), branch:
```swift
if let terminalView = run.terminalView {           // claude
    AgentTerminalView(session: run.backend as! AgentTerminalSession)
} else if let codex = run.backend as? CodexAppServerBackend {   // codex
    CodexTranscriptView(transcript: codex.transcript)
}
```
(Adjust to the actual view-composition in this file; the approval cards + composer below stay shared — `run.send(_:)` works for both backends.)

- [ ] **Step 2: Build**

```
cd apps/pendingcrew && xcodebuild ... build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```
git add apps/pendingcrew/Sources/Mac/Views/CrewSessionWindowView.swift
git commit -m "pendingcrew: inspector 按 kind 选视图 — claude 终端 / codex 结构化 transcript"
```

---

## Phase 6 — verify, ledger, real-machine tail

### Task 6.1: Full build + test sweep

- [ ] **Step 1: Build (macOS + iOS, both must stay green)**

```
cd apps/pendingcrew && xcodegen && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' build
xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'generic/platform=iOS Simulator' build
```
(The codex backend is `#if os(macOS)`; iOS build proves no leakage.)

- [ ] **Step 2: Unit tests**

```
cd apps/pendingcrew && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' test
```
Expected: all existing + new codex tests (RPCMessage 4, Dispatcher 4, ThreadItem 3, Transcript 2, Protocol 4, SessionConfig codex 3, env 2) pass. If the runner won't launch (PTY error), run the swiftc-driver fallback over the Foundation-only codex files and report which path was used.

### Task 6.2: Ledger updates

- [ ] **Step 1: tech-debt — log the deferred scope + real-machine tail**

Append to `docs/tech-debt.md` a 🟡 entry: codex app-server backend v1 ships core loop; **deferred** (item deltas/token streaming, turn/steer mid-turn injection, resume/fork, rate-limit display, peer rollout cross-read, hooks); **real-machine tail unverified** (auth model, one-turn render, approval roundtrip, developerInstructions append-vs-replace, billing tick) — must not be marked done on unit-green alone.

- [ ] **Step 2: progress.md — add the rollup line** (codex moved from placeholder terminal to app-server backend; what's verified vs the real-machine tail).

- [ ] **Step 3: Commit**

```
git add docs/tech-debt.md docs/progress.md
git commit -m "docs: 账本 — codex app-server backend v1(核心闭环) + defer 清单 + 真机尾巴"
```

### Task 6.3: Real-machine verification (NEEDS USER — codex login + Xcode GUI build)

> Do NOT mark the feature complete until these pass. Headless/CLI builds fall back to ad-hoc signing and the app-server child may not inherit the user's codex login. Run from Xcode GUI on the user's machine.

- [ ] Confirm the installed codex auth model: run `codex app-server`, send `initialize` then `account/read`; does it return the chatgpt account (auto-reads `~/.codex/auth.json`) or unauthenticated (needs client-driven `account/login/start`)? Adjust the boot gate accordingly.
- [ ] Capture a real `item/completed` line (or `generate-json-schema`) and reconcile `CodexThreadItem` field names.
- [ ] Start a codex session in a crew working dir; confirm a turn renders in `CodexTranscriptView` (message + a command-exec card).
- [ ] Trigger an approval (e.g. a write outside sandbox); confirm it surfaces in the existing approval UI and replying unblocks the agent.
- [ ] Confirm `developerInstructions` append-vs-replace semantics (world-model present but codex default behavior intact).
- [ ] Billing tick: after a real turn, `account/rateLimits/read` `usedPercent` ↑ and nothing appears on the API billing dashboard (subscription, not pay-as-you-go).

---

## Self-review (planner checklist — completed)

- **Spec coverage:** transport/handshake → T1.1/1.2/3.3; thread/turn → T2.3/3.4; ThreadItem→transcript → T2.1/2.2/5.1; interrupt/stop → T3.4; approvals → T3.4 + T4.1; additionalContext (world-model + whiteboard) → T2.3/4.1; crew MCP → T4.1; env billing guard → T3.2; effort → T3.1; backend abstraction → T0.1/0.2; view branch → T5.2; scope defer + tail → T6.2/6.3. ✓
- **Placeholder scan:** code blocks are concrete; the only deferred-to-real-machine items are the explicitly-flagged field-name reconciliation (T2.x caveat) and T6.3 — these are genuine real-machine dependencies, not lazy placeholders. ✓
- **Type consistency:** `SessionStatus` (`.running`/`.exited(Int32?)`) shared across `SessionBackend`, `AgentTerminalSession`, `CodexAppServerBackend`, `CrewSessionRun.map`. `CodexRPCMessage` cases (`.response`/`.serverRequest`/`.notification`) consumed unchanged by `CodexRPCDispatcher` and `CodexAppServerConnection`. `CodexProtocol` builders' param keys match what `CodexAppServerBackend` sends. `CodexThreadItem.Kind` arms match `CodexTranscriptView` switch. ✓
