# PendingBot Crew Real Data Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the local crew experience from shell/fixture UI to a usable real-data loop across PendingBot iOS/iPad, native PendingBot Mac, and PendingCrew.

**Architecture:** Keep PendingCrew as the heavy runner/workbench app and PendingBot as the IM-facing crew surface. Reuse the existing Edge crew/device-login routes and extend only the missing client-grant scope, then make the Mac companion and iOS crew tab consume the same crew summaries, relationships, sessions, and announcement concepts already exposed by the API. Cloud/Fly machine execution stays reserved.

**Tech Stack:** SwiftUI multiplatform package for shared big-screen UI, native SwiftPM macOS apps, iOS SwiftUI/Xcode project, Hono Edge routes, Vitest, SwiftPM/Xcode builds.

---

### Task 1: Edge Device Grant Scope

**Files:**
- Modify: `apps/edge/src/routes/device-login.ts`
- Modify: `apps/edge/tests/device-login.test.ts`

- [ ] Let `pendingbot_client` device grants request `subject:read`, `crew:read`, and `crew:write`, but not runner scopes.
- [ ] Add tests proving `pendingbot_macos` can be approved with crew scopes.
- [ ] Add tests proving `pendingbot_macos` still cannot request `runner:write`.
- [ ] Run `bun test tests/device-login.test.ts`.

### Task 2: PendingBot iOS Crew Surface

**Files:**
- Modify: `apps/ios/PendingBot/Features/Crew/CrewAPI.swift`
- Modify: `apps/ios/PendingBot/Features/Crew/CrewTabView.swift`

- [ ] Load links, members, responsibility shares, and announcements for the selected crew.
- [ ] Show parent/child crews, responsibility split, crew messages, and sessions in the detail pane.
- [ ] Add child-crew creation from the selected crew.
- [ ] Add crew announcement sending from PendingBot, with session/member targeting kept simple and safe.
- [ ] Make QR approval handle both PendingCrew and PendingBot Mac device-login challenges.

### Task 3: Shared Big-Screen Crew UI

**Files:**
- Modify: `apps/shared/PendingBotShared/Sources/PendingBotShared/PendingBotSharedModels.swift`
- Modify: `apps/shared/PendingBotShared/Sources/PendingBotShared/PendingBotBigScreenApp.swift`
- Modify: `apps/shared/PendingBotShared/Tests/PendingBotSharedTests/PendingBotBigScreenShellTests.swift`

- [ ] Add shared crew detail models for sessions, announcements, relationships, and responsibility shares.
- [ ] Replace the crew placeholder detail with a read/write-ready detail surface driven by injected data and callbacks.
- [ ] Keep the UI usable with empty/loading/error states.
- [ ] Add formatter/model tests for sorting and summaries.
- [ ] Run `swift test --package-path apps/shared/PendingBotShared`.

### Task 4: Native PendingBot Mac Real Data

**Files:**
- Modify: `apps/macos/PendingBot/Sources/PendingBotMac/PendingBotMacApp.swift`
- Create focused files under `apps/macos/PendingBot/Sources/PendingBotMac/` as needed.
- Modify: `apps/macos/PendingBot/README.md`

- [ ] Add native Mac app state for API URL, device-login challenge, saved device grant token, selected crew, and loaded crew details.
- [ ] Implement PendingBot Mac device login using `appKind: pendingbot_macos`, `grantKind: pendingbot_client`, and crew read/write scopes.
- [ ] Load real crew list and selected crew detail from Edge.
- [ ] Wire the shared big-screen crew UI to real Mac data and callbacks.
- [ ] Run `swift build --package-path apps/macos/PendingBot`.

### Task 5: PendingCrew Operator Finish

**Files:**
- Modify: `apps/macos/PendingCrew/Sources/PendingCrew/Views/CrewDetailView.swift`
- Modify tests under `apps/macos/PendingCrew/Tests/PendingCrewTests/` if model behavior changes.

- [ ] Make the selected session window show whether the session is claimable, locally active, or only observable.
- [ ] Add explicit controls for refresh, progress report, complete, and fail when the selected session is the active local runner session.
- [ ] Keep parent/child crew navigation visible from the workbench.
- [ ] Run `swift test --package-path apps/macos/PendingCrew`.

### Task 6: Integration Verification

**Files:**
- No new files unless a test requires a small fixture.

- [ ] Run Edge crew/device-login tests.
- [ ] Run PendingBotShared tests.
- [ ] Run PendingBot Mac build.
- [ ] Run PendingCrew tests and verify build script.
- [ ] Run iOS simulator build.
- [ ] Merge to local `main` only if checks pass and unrelated dirty files are untouched.
