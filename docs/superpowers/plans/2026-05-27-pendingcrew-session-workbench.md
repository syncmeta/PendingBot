# PendingCrew Session Workbench Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the PendingCrew crew detail screen act as the local session workbench by letting the selected session be claimed and run from the right-side window.

**Architecture:** Keep API/process orchestration in `AppModel`, keep view-only decision logic in focused value types, and keep `CrewDetailView` responsible for wiring selected crew/session UI actions. The first slice reuses the existing runner host claim/run APIs and adds narrow helpers so the workbench can claim a specific selected session when the backend returns it.

**Tech Stack:** SwiftUI, Swift Package tests, PendingCrew macOS `.xcodeproj`, existing PendingBot crew/runner HTTP API.

---

### Task 1: Session Workbench Action State

**Files:**
- Modify: `apps/macos/PendingCrew/Sources/PendingCrew/Views/CrewDetailView.swift`
- Test: `apps/macos/PendingCrew/Tests/PendingCrewTests/LocalCodingAgentRunnerTests.swift`

- [x] **Step 1: Write the failing test**

Add tests for a pure action-state helper:

```swift
func testSessionWorkbenchActionsExposeClaimAndRunStates() {
    let queued = Self.makeSession(id: "session-queued", status: "queued", runnerKind: .localCodex)
    let active = Self.makeSession(id: "session-active", status: "running", runnerKind: .localCodex)
    let finished = Self.makeSession(id: "session-finished", status: "completed", runnerKind: .localCodex)

    XCTAssertEqual(
        SessionWorkbenchActionState(session: queued, activeRunnerSessionId: nil).primaryAction,
        .claimAndRun
    )
    XCTAssertEqual(
        SessionWorkbenchActionState(session: active, activeRunnerSessionId: "session-active").primaryAction,
        .runActive
    )
    XCTAssertEqual(
        SessionWorkbenchActionState(session: finished, activeRunnerSessionId: nil).primaryAction,
        .none
    )
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `swift test --package-path apps/macos/PendingCrew --filter LocalCodingAgentRunnerTests/testSessionWorkbenchActionsExposeClaimAndRunStates`

Expected: FAIL because `SessionWorkbenchActionState` does not exist.

- [x] **Step 3: Write minimal implementation**

Add `SessionWorkbenchPrimaryAction` and `SessionWorkbenchActionState` near `SessionOperatorState` in `CrewDetailView.swift`, deriving action from selected session status and active runner session id.

- [x] **Step 4: Run test to verify it passes**

Run: `swift test --package-path apps/macos/PendingCrew --filter LocalCodingAgentRunnerTests/testSessionWorkbenchActionsExposeClaimAndRunStates`

Expected: PASS.

### Task 2: Claim Selected Session From Workbench

**Files:**
- Modify: `apps/macos/PendingCrew/Sources/PendingCrew/Stores/AppModel.swift`
- Modify: `apps/macos/PendingCrew/Sources/PendingCrew/Views/CrewDetailView.swift`
- Test: `apps/macos/PendingCrew/Tests/PendingCrewTests/LocalCodingAgentRunnerTests.swift`

- [x] **Step 1: Write the failing test**

Add a pure helper test that confirms a claim result only activates the selected session when the backend returned the same id:

```swift
func testSelectedSessionClaimResultRequiresMatchingSession() {
    let selected = Self.makeSession(id: "session-selected", status: "queued", runnerKind: .localCodex)
    let other = Self.makeSession(id: "session-other", status: "queued", runnerKind: .localCodex)

    XCTAssertTrue(SelectedSessionClaimDecision(session: selected, selectedSessionId: "session-selected").matchesSelection)
    XCTAssertFalse(SelectedSessionClaimDecision(session: other, selectedSessionId: "session-selected").matchesSelection)
    XCTAssertFalse(SelectedSessionClaimDecision(session: nil, selectedSessionId: "session-selected").matchesSelection)
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `swift test --package-path apps/macos/PendingCrew --filter LocalCodingAgentRunnerTests/testSelectedSessionClaimResultRequiresMatchingSession`

Expected: FAIL because `SelectedSessionClaimDecision` does not exist.

- [x] **Step 3: Write minimal implementation**

Add `SelectedSessionClaimDecision` as a small `Equatable` value near the other session view models. Add `AppModel.claimSelectedSession(hostId:kinds:selectedSessionId:)` that calls the existing claim API, activates only when the returned session matches, refreshes crew/session state, and reports a clear status if another queued session was claimed.

- [x] **Step 4: Run test to verify it passes**

Run: `swift test --package-path apps/macos/PendingCrew --filter LocalCodingAgentRunnerTests/testSelectedSessionClaimResultRequiresMatchingSession`

Expected: PASS.

### Task 3: Wire Workbench Buttons

**Files:**
- Modify: `apps/macos/PendingCrew/Sources/PendingCrew/Views/CrewDetailView.swift`
- Modify: `apps/macos/PendingCrew/Sources/PendingCrew/Views/RunnerHostsView.swift`

- [x] **Step 1: Update selected session window initializer**

Pass closures for `onClaimAndRun` and `onRunActive` into `SelectedSessionWindow`.

- [x] **Step 2: Add visible workbench action buttons**

When `SessionWorkbenchActionState.primaryAction == .claimAndRun`, show a primary button labeled `认领并运行`; when `.runActive`, show `运行本机 session`; when `.none`, disable operator actions and keep finish controls only for active local sessions.

- [x] **Step 3: Reuse existing runner host state**

Use `model.activeRunnerHostId` when available. If no runner host is active, use the first online host from `model.runnerHosts` that supports the selected runner kind.

- [x] **Step 4: Run focused tests**

Run: `swift test --package-path apps/macos/PendingCrew --filter LocalCodingAgentRunnerTests`

Expected: PASS.

### Task 4: Verify App Build

**Files:**
- Validate: `apps/macos/PendingCrew`

- [x] **Step 1: Run full PendingCrew tests**

Run: `swift test --package-path apps/macos/PendingCrew`

Expected: all tests pass.

- [x] **Step 2: Run macOS app verification**

Run: `apps/macos/PendingCrew/script/build_and_run.sh --verify`

Expected: exit 0.

- [x] **Step 3: Check diff hygiene**

Run: `git diff --check`

Expected: no output.

### Task 5: Local Workspace Execution Policy

**Files:**
- Modify: `apps/macos/PendingCrew/Sources/PendingCrew/Services/LocalCodingAgentRunner.swift`
- Modify: `apps/macos/PendingCrew/Sources/PendingCrew/Stores/AppModel.swift`
- Modify: `apps/macos/PendingCrew/Sources/PendingCrew/Views/CrewDetailView.swift`
- Modify: `apps/macos/PendingCrew/Sources/PendingCrew/Views/RunnerHostsView.swift`
- Modify: `apps/macos/PendingCrew/Sources/PendingCrew/Views/SettingsView.swift`
- Test: `apps/macos/PendingCrew/Tests/PendingCrewTests/LocalCodingAgentRunnerTests.swift`

- [x] **Step 1: Write the failing workspace policy test**

Run: `swift test --package-path apps/macos/PendingCrew --filter LocalCodingAgentRunnerTests/testLocalWorkspacePolicyRequiresAbsoluteExistingDirectory`

Expected: FAIL because `LocalWorkspacePolicy` does not exist.

- [x] **Step 2: Add the minimal workspace policy**

`LocalWorkspacePolicy` accepts only non-empty absolute paths that exist and are directories.

- [x] **Step 3: Wire policy into local execution**

`AppModel.runActiveSessionLocally()` now throws `LocalError.invalidLocalWorkspace` before launching a local process when the configured workspace is invalid.

- [x] **Step 4: Expose policy in the UI**

Crew detail, Runner, and Settings now share the same policy so buttons and guidance match the actual execution guard.

- [x] **Step 5: Run focused tests**

Run: `swift test --package-path apps/macos/PendingCrew --filter LocalCodingAgentRunnerTests`

Expected: PASS.
