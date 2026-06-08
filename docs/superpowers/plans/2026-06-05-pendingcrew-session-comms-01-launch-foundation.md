# PendingCrew session-comms — Plan 01: Launch Foundation (claude-first) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor the claude PTY runner launch path so the session's first instruction + model + thinking-effort + permission mode are passed **in argv at spawn** (auto mode, not bypass; no post-spawn sleep), via a pure, unit-tested `SessionConfig`.

**Architecture:** Introduce a value-type `SessionConfig` whose `argv()` builds the interactive-CLI argument vector. `AgentTerminalSession` / `CrewSessionRunner` / `CrewSessionWindowView` take `SessionConfig` instead of loose `kind`/`model`/`permissionModeOverride` params. claude launches `claude --permission-mode auto [--model m] [--effort e] "<prompt>"` — instruction baked into the positional prompt, killing the brittle 0.6s "wait for REPL then inject" hack. codex's PTY argv is left unchanged (it moves to app-server in a later plan).

**Tech Stack:** Swift 5 / SwiftUI / XcodeGen, macOS-only (`#if os(macOS)`), SwiftTerm `LocalProcessTerminalView`, XCTest (`PendingCrewTests` bundle, which compiles `Sources/Mac/LocalRunner` directly).

**Spec:** `docs/superpowers/specs/2026-06-05-pendingcrew-session-crew-comms-design.md` §1 (启动带指令), §9 (auto mode 非 bypass), §11 (per-session 配置).

**Branch / worktree:** `feat/session-crew-comms` (this worktree). All paths are repo-relative. Build/test from `apps/pendingcrew`.

**Pre-flight (run once before Task 1):**
```bash
cd apps/pendingcrew && xcodegen generate
xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' build 2>&1 | tail -3
# Expected: ** BUILD SUCCEEDED ** (baseline green before changes)
```

> ⚠️ **xcodegen gotcha:** the `.xcodeproj` is committed; a NEW source file is NOT in the target until `xcodegen generate` re-runs. After creating `SessionConfig.swift` (Task 1) you MUST re-run `xcodegen generate` or the file won't compile into the target/tests (false-green). Tasks below call it explicitly.

---

## File Structure

- **Create** `apps/pendingcrew/Sources/Mac/LocalRunner/SessionConfig.swift` — the value type + `argv()` builder (one responsibility: launch config → CLI args).
- **Create** `apps/pendingcrew/Tests/PendingCrewTests/SessionConfigTests.swift` — unit tests for `argv()`.
- **Modify** `apps/pendingcrew/Sources/Mac/LocalRunner/AgentTerminalSession.swift` — `init` takes `SessionConfig`; delete the old `argv(kind:model:resumeSessionId:)` + `--dangerously-skip-permissions`.
- **Modify** `apps/pendingcrew/Sources/Mac/Services/CrewSessionRunner.swift` — `start(...)` takes `SessionConfig`; `CrewSessionRun` stores it.
- **Modify** `apps/pendingcrew/Sources/Mac/Views/CrewSessionWindowView.swift` — build `SessionConfig` with `initialPrompt`; delete the two 0.6s `Task.sleep` + `run.send(firstPrompt/brief)` blocks.

---

## Task 1: `SessionConfig` value type + `argv()` builder (TDD)

**Files:**
- Create: `apps/pendingcrew/Sources/Mac/LocalRunner/SessionConfig.swift`
- Test: `apps/pendingcrew/Tests/PendingCrewTests/SessionConfigTests.swift`

- [ ] **Step 1: Write the failing test**

Create `apps/pendingcrew/Tests/PendingCrewTests/SessionConfigTests.swift`:

```swift
import XCTest
@testable import PendingCrew

final class SessionConfigTests: XCTestCase {
    func testClaudeArgvUsesAutoModeNotBypass() {
        let cfg = SessionConfig(kind: .claudeCode, initialPrompt: "do the thing")
        let argv = cfg.argv()
        XCTAssertFalse(argv.contains("--dangerously-skip-permissions"),
                       "claude must NOT bypass permissions (spec §9 auto mode)")
        XCTAssertEqual(argv, ["--permission-mode", "auto", "do the thing"])
    }

    func testClaudeArgvPositionalPromptIsLast() {
        let cfg = SessionConfig(kind: .claudeCode, model: "opus", effort: "high",
                                initialPrompt: "fix bug")
        XCTAssertEqual(cfg.argv(),
                       ["--permission-mode", "auto", "--model", "opus", "--effort", "high", "fix bug"])
    }

    func testClaudeArgvOmitsEmptyOptionalsAndEmptyPrompt() {
        let cfg = SessionConfig(kind: .claudeCode, initialPrompt: "")
        XCTAssertEqual(cfg.argv(), ["--permission-mode", "auto"])
    }

    func testClaudeArgvResumePrependsResumeFlag() {
        let cfg = SessionConfig(kind: .claudeCode, initialPrompt: "go", resumeSessionId: "abc123")
        XCTAssertEqual(cfg.argv(),
                       ["--resume", "abc123", "--permission-mode", "auto", "go"])
    }

    func testCodexArgvUnchangedPlaceholder() {
        // codex PTY argv is a placeholder until the app-server plan; keep sandbox, carry prompt.
        let cfg = SessionConfig(kind: .codex, model: "gpt-5.5", initialPrompt: "ship it")
        XCTAssertEqual(cfg.argv(),
                       ["--sandbox", "workspace-write", "--model", "gpt-5.5", "ship it"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd apps/pendingcrew && xcodegen generate
xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' test 2>&1 | tail -20
```
Expected: FAIL — compile error "cannot find 'SessionConfig' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `apps/pendingcrew/Sources/Mac/LocalRunner/SessionConfig.swift`:

```swift
#if os(macOS)
import Foundation

/// Per-session launch configuration (spec §1 启动带指令 / §11 per-session 配置).
/// Pure value type so `argv()` is unit-testable without spawning a process.
public struct SessionConfig: Sendable, Equatable {
    public var kind: LocalCodingAgentKind
    /// `--model` (claude) / `-m` (codex). `nil` → let the CLI use its default.
    public var model: String?
    /// Thinking effort: claude `--effort <level>` / codex `model_reasoning_effort`.
    /// Passthrough string — valid levels are CLI-owned (UI validates; see spec probe §11).
    public var effort: String?
    /// The session's first instruction, passed as the positional prompt at launch
    /// (spec §1 — kills the post-spawn 0.6s sleep+inject).
    public var initialPrompt: String?
    /// Resume an existing agent session by id.
    public var resumeSessionId: String?
    /// claude permission mode. **Default "auto" = auto mode classifier (spec §9); never bypass.**
    public var permissionMode: String

    public init(kind: LocalCodingAgentKind,
                model: String? = nil,
                effort: String? = nil,
                initialPrompt: String? = nil,
                resumeSessionId: String? = nil,
                permissionMode: String = "auto") {
        self.kind = kind
        self.model = model
        self.effort = effort
        self.initialPrompt = initialPrompt
        self.resumeSessionId = resumeSessionId
        self.permissionMode = permissionMode
    }

    /// Build the interactive-CLI argv. The session's instruction is the trailing
    /// positional prompt — both CLIs start an interactive (subscription-billed)
    /// session by default; only `-p`/`exec` go headless, which we never use.
    public func argv() -> [String] {
        switch kind {
        case .claudeCode:
            var a: [String] = []
            if let id = resumeSessionId, !id.isEmpty { a += ["--resume", id] }
            a += ["--permission-mode", permissionMode] // "auto", NOT --dangerously-skip-permissions
            if let m = model, !m.isEmpty { a += ["--model", m] }
            if let e = effort, !e.isEmpty { a += ["--effort", e] }
            if let p = initialPrompt, !p.isEmpty { a.append(p) } // positional prompt LAST
            return a
        case .codex:
            // Placeholder until codex moves to app-server (separate plan). Keep the FS sandbox.
            var a: [String] = []
            if let id = resumeSessionId, !id.isEmpty { a += ["resume", id] }
            a += ["--sandbox", "workspace-write"]
            if let m = model, !m.isEmpty { a += ["--model", m] }
            if let p = initialPrompt, !p.isEmpty { a.append(p) }
            return a
        }
    }
}
#endif
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd apps/pendingcrew && xcodegen generate
xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' test 2>&1 | tail -20
```
Expected: `Test Suite 'SessionConfigTests' passed` — 5/5.

- [ ] **Step 5: Commit**

```bash
git add apps/pendingcrew/Sources/Mac/LocalRunner/SessionConfig.swift \
        apps/pendingcrew/Tests/PendingCrewTests/SessionConfigTests.swift \
        apps/pendingcrew/PendingCrew.xcodeproj/project.pbxproj
git commit -m "feat(pendingcrew): SessionConfig + argv builder — claude auto mode + effort + positional prompt"
```

---

## Task 2: `AgentTerminalSession` takes `SessionConfig`

**Files:**
- Modify: `apps/pendingcrew/Sources/Mac/LocalRunner/AgentTerminalSession.swift`

Current `init(kind:executable:workdir:model:resumeSessionId:env:)` (line ~25) calls the static `argv(kind:model:resumeSessionId:)` (line ~44, contains `--dangerously-skip-permissions`). Replace both with a `SessionConfig`-driven init.

- [ ] **Step 1: Replace the init signature + argv call**

In `AgentTerminalSession.swift`, change the `init` to:

```swift
    /// `executable` = resolved claude/codex absolute path; `workdir` = working dir.
    init(config: SessionConfig, executable: String, workdir: String, env: [String: String]) {
        self.kind = config.kind
        self.terminalView = LocalProcessTerminalView(frame: .zero)
        self.terminalView.processDelegate = delegate
        delegate.onExit = { [weak self] code in
            Task { @MainActor in self?.status = .exited(code) }
        }
        var envArr = env.map { "\($0.key)=\($0.value)" }
        if !envArr.contains(where: { $0.hasPrefix("TERM=") }) { envArr.append("TERM=xterm-256color") }
        terminalView.startProcess(
            executable: executable,
            args: config.argv(),
            environment: envArr,
            currentDirectory: workdir
        )
    }
```

- [ ] **Step 2: Delete the old static `argv(kind:model:resumeSessionId:)` function**

Remove the entire `static func argv(kind:model:resumeSessionId:) -> [String] { … }` block (it's now on `SessionConfig`). Leave `send` / `interrupt` / `stop` / `inject` untouched.

- [ ] **Step 3: Build to verify it compiles (callers will break — fixed in Task 3)**

```bash
cd apps/pendingcrew && xcodegen generate
xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD" | head
```
Expected: errors ONLY in `CrewSessionRunner.swift` (the one caller of the old init) — that's expected, fixed next. If errors appear in any OTHER file, stop and investigate.

- [ ] **Step 4: Commit (compile-broken-by-design checkpoint is fine in a feature branch)**

```bash
git add apps/pendingcrew/Sources/Mac/LocalRunner/AgentTerminalSession.swift
git commit -m "refactor(pendingcrew): AgentTerminalSession.init takes SessionConfig (drops --dangerously-skip-permissions)"
```

---

## Task 3: `CrewSessionRunner.start` takes `SessionConfig`

**Files:**
- Modify: `apps/pendingcrew/Sources/Mac/Services/CrewSessionRunner.swift`

Current `start(crewId:kind:workingDirectory:taskBrief:model:additionalEnv:permissionModeOverride:serverLink:)` (line ~62) builds `AgentTerminalSession(kind:executable:workdir:model:env:)`. Thread a `SessionConfig` through.

- [ ] **Step 1: Change `start` to accept `SessionConfig`**

Replace the `start` signature + the `AgentTerminalSession(...)` construction:

```swift
    func start(
        crewId: String,
        config: SessionConfig,
        workingDirectory: URL,
        taskBrief: String,
        additionalEnv: [String: String] = [:],
        serverLink: CrewSessionServerLink? = nil
    ) async throws {
        guard let executable = LocalCodingAgentExecutable.resolve(config.kind) else {
            throw RunnerError.toolNotInstalled(kind: config.kind)
        }
        let env = LocalCodingAgentEnv.build(additionalEnv: additionalEnv)
        let terminalSession = AgentTerminalSession(
            config: config,
            executable: executable.path,
            workdir: workingDirectory.path,
            env: env
        )
        let run = CrewSessionRun(
            crewId: crewId,
            kind: config.kind,
            taskBrief: taskBrief,
            workingDirectory: workingDirectory,
            model: config.model,
            permissionModeOverride: config.permissionMode,
            terminalSession: terminalSession,
            serverLink: serverLink
        )
        current?.stop()
        current = run
    }
```

(Keep `CrewSessionRun`'s stored properties as-is — `model`/`permissionModeOverride` are still informational metadata.)

- [ ] **Step 2: Build to verify CrewSessionRunner compiles (callers in the View break — fixed Task 4)**

```bash
cd apps/pendingcrew && xcodegen generate
xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD" | head
```
Expected: errors ONLY in `CrewSessionWindowView.swift` (the two `sessionRunner.start(...)` call sites) — fixed next.

- [ ] **Step 3: Commit**

```bash
git add apps/pendingcrew/Sources/Mac/Services/CrewSessionRunner.swift
git commit -m "refactor(pendingcrew): CrewSessionRunner.start takes SessionConfig"
```

---

## Task 4: `CrewSessionWindowView` — prompt in argv, delete the 0.6s sleep

**Files:**
- Modify: `apps/pendingcrew/Sources/Mac/Views/CrewSessionWindowView.swift`

Two call sites build a session then `Task { sleep 0.6s; run.send(firstPrompt/brief) }`. Replace each: pass the instruction as `SessionConfig.initialPrompt`, delete the sleep+send.

- [ ] **Step 1: `startSession(firstPrompt:)` — config carries the prompt, drop the sleep**

In `startSession(firstPrompt:)`, replace the `sessionRunner.start(...)` call + the trailing inject block with:

```swift
        do {
            try await sessionRunner.start(
                crewId: detail.crew.id,
                config: SessionConfig(kind: selectedKind, initialPrompt: firstPrompt),
                workingDirectory: dir,
                taskBrief: firstPrompt,
                serverLink: serverLink
            )
            // Instruction is in argv now — no REPL-ready sleep, no post-spawn inject.
            draft = ""
        } catch {
            localError = error.localizedDescription
        }
```

Delete the old:
```swift
            if let run = sessionRunner.current {
                Task {
                    try? await Task.sleep(nanoseconds: 600_000_000) // 0.6s
                    run.send(firstPrompt)
                }
            }
```

- [ ] **Step 2: `runQueuedSession(...)` — same change for captain-queued sessions**

In `runQueuedSession`, replace its `sessionRunner.start(...)` + inject block with:

```swift
            try await sessionRunner.start(
                crewId: detail.crew.id,
                config: SessionConfig(kind: kind, initialPrompt: s.taskBrief),
                workingDirectory: dir,
                taskBrief: s.taskBrief,
                serverLink: link
            )
            // taskBrief is in argv — no 0.6s sleep + send(brief).
```

Delete the old:
```swift
            if let run = sessionRunner.current {
                let brief = s.taskBrief
                Task {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    run.send(brief)
                }
            }
```

(The existing `let kind: LocalCodingAgentKind = s.runnerKind.contains("codex") ? .codex : .claudeCode` line stays — it feeds `SessionConfig(kind:)`.)

- [ ] **Step 3: Build to verify the whole app compiles green**

```bash
cd apps/pendingcrew && xcodegen generate
xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run the full test bundle (argv tests + existing runner tests stay green)**

```bash
cd apps/pendingcrew
xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' test 2>&1 | tail -8
```
Expected: all suites pass (SessionConfigTests 5/5 + AgentTerminationTests + GitWorktreeServiceTests + LocalCodingAgentTests + SessionProxyProtocolTests).

- [ ] **Step 5: Commit**

```bash
git add apps/pendingcrew/Sources/Mac/Views/CrewSessionWindowView.swift
git commit -m "refactor(pendingcrew): session 启动指令进 argv,删 0.6s REPL-ready sleep + 事后注入"
```

---

## Task 5: Tidy + ledger

**Files:**
- Modify: `docs/progress.md` (top reconciliation block)

- [ ] **Step 1: Grep for any stale references to the removed APIs**

```bash
cd apps/pendingcrew
grep -rn "dangerously-skip-permissions\|\.argv(kind:" Sources/ || echo "clean: no stale refs"
```
Expected: `clean` (the only `--dangerously-skip-permissions` mention left in the repo should be in spec/docs, not Swift source).

- [ ] **Step 2: Note the foundation in the progress ledger**

Add a dated bullet near the top of `docs/progress.md` recording: Plan 01 launch-foundation landed (SessionConfig + claude auto mode argv + prompt-in-argv, 0.6s sleep removed), build+tests green, on `feat/session-crew-comms`.

- [ ] **Step 3: Commit**

```bash
git add docs/progress.md
git commit -m "docs(progress): Plan 01 launch-foundation 落地(SessionConfig + claude auto mode argv + 删 sleep)"
```

---

## Self-Review checklist (run before handoff)

- **Spec coverage:** §1 启动带指令 → Task 1+4 (positional prompt, sleep removed) ✓. §9 auto mode 非 bypass → Task 1 (`--permission-mode auto`, drop `--dangerously-skip-permissions`) ✓. §11 per-session 配置 → Task 1 (`SessionConfig` model/effort) ✓. (NOT in this plan: worktree isolation orchestration, RunnerBackend protocol, statusLine/hooks/MCP/crew-comms — those are later plans, by design.)
- **Type consistency:** `SessionConfig(kind:model:effort:initialPrompt:resumeSessionId:permissionMode:)` used identically in Tasks 1/3/4. `argv()` no-arg method everywhere. `AgentTerminalSession.init(config:executable:workdir:env:)` matches Task 2 ↔ Task 3 caller.
- **No placeholders:** all code blocks complete; no TBD.

## Out of scope (later plans, claude-first)
- **02 — worktree isolation + RunnerBackend protocol** (§11 isolation, §Runner-split abstraction).
- **03 — crew-comms re-wire** (§2 world-view append-prompt, §3 UserPromptSubmit whiteboard hook + read/unread idle inject, §4 MCP crew-comms tools reconnect to post_to_crew/SessionProxy).
- **04 — status + quota** (§5 transcript turn-boundary + Notification, §7 statusLine sidecar: cost/context/rate_limits).
- **05 — captain approval triage + terminate** (§6, §9 Layer 2: ask_human→captain→human).
- **06 — long-run resilience** (§8 SessionStart/PreCompact re-inject).
- **07 — identity tags + cross-read** (§10).
- **Phase 2: codex app-server backend** (pending background research a5418a67…).
