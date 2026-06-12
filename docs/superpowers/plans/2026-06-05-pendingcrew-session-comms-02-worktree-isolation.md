# PendingCrew session-comms — Plan 02: Per-session Worktree Isolation

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or executing-plans. Checkbox steps.

**Goal:** Per-session `isolation` toggle — on → run the session in a fresh git worktree (parallel sessions don't clobber each other; claude's containment boundary per spec §8); off → use the crew's shared working dir.

**Architecture:** `GitWorktreeService` (already exists, currently wired nowhere) does `git worktree add` and returns the new dir URL. Add `isolation: Bool` to `SessionConfig`; a small `SessionWorkspace.resolve(...)` picks shared-dir vs new-worktree; `CrewSessionWindowView` calls it before `start`. Fail-soft: non-git dir → fall back to shared dir.

**Spec:** §8 (claude containment = worktree), §11 (per-session isolation toggle). **Branch:** `feat/session-crew-comms`. Build/test from `apps/pendingcrew`.

**Files:**
- Modify: `apps/pendingcrew/Sources/Mac/LocalRunner/SessionConfig.swift` (add `isolation`)
- Modify: `apps/pendingcrew/Tests/PendingCrewTests/SessionConfigTests.swift` (isolation doesn't leak into argv)
- Create: `apps/pendingcrew/Sources/Mac/LocalRunner/SessionWorkspace.swift` (resolver)
- Modify: `apps/pendingcrew/Sources/Mac/Views/CrewSessionWindowView.swift` (call resolver before start)

---

## Task 1: `SessionConfig.isolation` (TDD — argv must ignore it)

- [ ] **Step 1: Add failing test** to `SessionConfigTests.swift`:

```swift
    func testIsolationDoesNotLeakIntoArgv() {
        let isolated = SessionConfig(kind: .claudeCode, initialPrompt: "go", isolation: true)
        let shared = SessionConfig(kind: .claudeCode, initialPrompt: "go", isolation: false)
        XCTAssertEqual(isolated.argv(), shared.argv(), "isolation 是编排参数,不是 CLI flag")
        XCTAssertEqual(isolated.argv(), ["--permission-mode", "auto", "go"])
    }
```

- [ ] **Step 2: Run — fails** (`extra argument 'isolation'`):
```bash
cd apps/pendingcrew && xcodegen generate && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' test 2>&1 | grep -E "error:|isolation" | head
```

- [ ] **Step 3: Add the field** to `SessionConfig.swift` — after `permissionMode` property add:
```swift
    /// 隔离:on → session 跑在独立 git worktree（并行不打架 + claude containment §8）；
    /// off → 用 crew 共享目录。编排参数,不进 argv。
    public var isolation: Bool
```
And in `init`, add param `isolation: Bool = false,` (before `permissionMode`) and `self.isolation = isolation`.

- [ ] **Step 4: Run — passes:**
```bash
cd apps/pendingcrew && xcodegen generate && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' test 2>&1 | grep -E "Test Suite 'SessionConfigTests'|error:" | head
```
Expected: `SessionConfigTests' passed`.

- [ ] **Step 5: Commit:**
```bash
git add apps/pendingcrew/Sources/Mac/LocalRunner/SessionConfig.swift apps/pendingcrew/Tests/PendingCrewTests/SessionConfigTests.swift apps/pendingcrew/PendingCrew.xcodeproj/project.pbxproj
git commit -m "feat(pendingcrew): SessionConfig.isolation 字段(编排参数,不进 argv)"
```

---

## Task 2: `SessionWorkspace.resolve` — shared dir vs fresh worktree

- [ ] **Step 1: Create** `apps/pendingcrew/Sources/Mac/LocalRunner/SessionWorkspace.swift`:

```swift
#if os(macOS)
import Foundation

/// 解析 session 的工作目录(spec §8/§11 worktree 隔离)。
/// isolation=on 且 crew 目录是 git repo → 在当前分支上开一个独立 worktree(新分支);
/// 否则(off / 非 git repo)→ 用 crew 共享目录(fail-soft)。
enum SessionWorkspace {
    static func resolve(crewDirectory: URL, isolation: Bool, hint: String) -> URL {
        guard isolation else { return crewDirectory }
        guard (try? GitWorktreeService.isGitRepository(at: crewDirectory)) == true else {
            print("[session-workspace] isolation 要求但 \(crewDirectory.path) 非 git repo → 退回共享目录")
            return crewDirectory
        }
        let base = (try? GitWorktreeService.currentBranch(at: crewDirectory)) ?? nil
        guard let baseBranch = base else {
            print("[session-workspace] 拿不到当前分支(detached?) → 退回共享目录")
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
            print("[session-workspace] worktree add 失败(\(error)) → 退回共享目录")
            return crewDirectory
        }
    }
}
#endif
```

- [ ] **Step 2: Build** (new file compiles):
```bash
cd apps/pendingcrew && xcodegen generate && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit:**
```bash
git add apps/pendingcrew/Sources/Mac/LocalRunner/SessionWorkspace.swift apps/pendingcrew/PendingCrew.xcodeproj/project.pbxproj
git commit -m "feat(pendingcrew): SessionWorkspace.resolve — isolation 时开独立 worktree,否则共享目录(fail-soft)"
```

---

## Task 3: Wire into `CrewSessionWindowView.startSession`

In `startSession(firstPrompt:)`, the current line computes `dir` from the crew working dir, then passes it to `start`. Route through the resolver.

- [ ] **Step 1: Resolve workdir before start.** Find the line `let dir = URL(fileURLWithPath: (wd as NSString).expandingTildeInPath)` in `startSession`. Immediately after building the `SessionConfig`, change the `start(..., workingDirectory: dir, ...)` call to resolve first. Concretely, replace the `try await sessionRunner.start(...)` block in `startSession` with:

```swift
            let cfg = SessionConfig(kind: selectedKind, initialPrompt: firstPrompt)
            let workdir = SessionWorkspace.resolve(
                crewDirectory: dir, isolation: cfg.isolation, hint: firstPrompt)
            try await sessionRunner.start(
                crewId: detail.crew.id,
                config: cfg,
                workingDirectory: workdir,
                taskBrief: firstPrompt,
                serverLink: serverLink
            )
            draft = ""
```

(`cfg.isolation` is `false` by default this plan — the toggle UI is a later plan; this wires the path so flipping the default / a future picker just works.)

- [ ] **Step 2: Build green:**
```bash
cd apps/pendingcrew && xcodegen generate && xcodebuild -project PendingCrew.xcodeproj -scheme PendingCrew -destination 'platform=macOS' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Manual smoke (real git worktree create/remove) — optional, proves the wire:**
```bash
# In a throwaway git repo, confirm GitWorktreeService path works end to end:
cd /tmp && rm -rf cxwt && mkdir cxwt && cd cxwt && git init -q && git commit -q --allow-empty -m init
# (the Swift path is covered by GitWorktreeServiceTests; this is just a sanity ref)
```

- [ ] **Step 4: Commit + ledger:**
```bash
git add apps/pendingcrew/Sources/Mac/Views/CrewSessionWindowView.swift
git commit -m "feat(pendingcrew): startSession 经 SessionWorkspace 解析工作目录(isolation→worktree)"
```

---

## Self-review
- Spec §8/§11 isolation → Task 1-3 ✓. `runQueuedSession` (captain-queued) intentionally left on shared dir for now (captain sessions default non-isolated; revisit if needed) — note in ledger.
- Type consistency: `SessionConfig(... isolation:)` ↔ `SessionWorkspace.resolve(isolation:)` ↔ `GitWorktreeService.addWorktree`.

## Out of scope (later)
- Isolation toggle UI + crew-default. Worktree cleanup-on-session-end policy. `runQueuedSession` isolation. RunnerBackend protocol (codex-backend plan).
