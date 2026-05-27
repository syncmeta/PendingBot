# PendingBot Multiplatform Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first native SwiftUI Multiplatform foundation for PendingBot iPad and macOS while preserving the existing iPhone compact path.

**Architecture:** Keep the current iOS target and iPhone `TabView` flow intact. Add a cross-platform Swift package for big-screen PendingBot UI and a native macOS PendingBot app target that consumes it. Move only the first Crew/IM shell into shared code so iPad and macOS can converge without destabilizing phone chat.

**Tech Stack:** SwiftUI, SwiftPM, native macOS app target, existing PendingBot Worker REST APIs.

---

### Task 1: Shared Package Foundation

**Files:**
- Create: `apps/shared/PendingBotShared/Package.swift`
- Create: `apps/shared/PendingBotShared/Sources/PendingBotShared/PendingBotBigScreenApp.swift`
- Create: `apps/shared/PendingBotShared/Sources/PendingBotShared/PendingBotSharedModels.swift`
- Create: `apps/shared/PendingBotShared/Tests/PendingBotSharedTests/PendingBotBigScreenShellTests.swift`

- [ ] Add a SwiftPM package named `PendingBotShared` with iOS 17 and macOS 14 platforms.
- [ ] Add shared value models for big-screen tabs, sidebar entries, and Crew summaries.
- [ ] Add a SwiftUI `PendingBotBigScreenAppView` that renders a sidebar-detail shell with Message, Crew, Envelope, and Me sections.
- [ ] Add unit tests for tab ordering and Crew sidebar row generation.
- [ ] Run `swift test --package-path apps/shared/PendingBotShared`.
- [ ] Commit as `feat: add PendingBot shared big screen shell`.

### Task 2: Native macOS PendingBot App

**Files:**
- Create: `apps/macos/PendingBot/Package.swift`
- Create: `apps/macos/PendingBot/Sources/PendingBotMac/PendingBotMacApp.swift`
- Create: `apps/macos/PendingBot/Sources/PendingBotMac/MacPendingBotBootstrap.swift`
- Create: `apps/macos/PendingBot/README.md`
- Create: `apps/macos/PendingBot/script/build_and_run.sh`

- [ ] Add a native macOS SwiftUI app package named `PendingBotMac`.
- [ ] Depend on `PendingBotShared` by relative path.
- [ ] Launch `PendingBotBigScreenAppView` in a regular macOS `WindowGroup`.
- [ ] Keep authentication as a bootstrap placeholder in this slice; do not reuse Catalyst or UIKit.
- [ ] Run `swift build --package-path apps/macos/PendingBot`.
- [ ] Commit as `feat: add native PendingBot Mac shell`.

### Task 3: iPad Integration Preparation

**Files:**
- Modify: `apps/ios/PendingBot/Features/Root/TabRoot.swift`
- Modify: `apps/ios/PendingBot/Features/Crew/CrewTabView.swift`
- Modify: `apps/ios/PendingBot.xcodeproj/project.pbxproj`

- [ ] Add the local `PendingBotShared` Swift package to the iOS project.
- [ ] Keep `compactBody` unchanged for iPhone.
- [ ] Gate the new shared big-screen shell behind `useSidebarLayout`.
- [ ] Initially wire Crew tab data through existing `CrewAPI.swift`, not a second network client.
- [ ] Build the iOS simulator target when the local SDK allows it; if unavailable, document the SDK blocker.
- [ ] Commit as `feat: route iPad through shared PendingBot shell`.

### Task 4: Verification

**Files:**
- No planned file edits.

- [ ] Run `swift test --package-path apps/shared/PendingBotShared`.
- [ ] Run `swift build --package-path apps/macos/PendingBot`.
- [ ] Run `swift test --package-path apps/macos/PendingCrew` to ensure the split did not regress existing Crew tooling.
- [ ] Run `bun test tests/crew.test.ts tests/migrations-security.test.ts` from `apps/edge`.
- [ ] Run `bun run typecheck` from `apps/edge`.
- [ ] Run `git diff --check`.
