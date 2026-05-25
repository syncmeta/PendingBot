# Security Foundation Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace short-term service-role and duplicated voice billing patterns with auditable shared primitives before production users exist.

**Architecture:** Add narrow shared modules at the Edge boundary instead of spreading resource authorization and voice metering across route files. Routes should prove caller access through a reusable helper, then use service-role only for privileged reads/writes that follow that proof.

**Tech Stack:** Hono Edge routes, Supabase service/user clients, Vitest route/unit tests, TypeScript.

---

### Task 1: Shared Route Authorization Helpers

**Files:**
- Create: `apps/edge/src/lib/route-authz.ts`
- Test: `apps/edge/tests/route-authz.test.ts`
- Modify: `apps/edge/src/routes/group-voice.ts`
- Modify: `apps/edge/src/routes/groups.ts`
- Modify: `docs/tech-debt.md`

- [x] **Step 1: Write failing tests**

Create `apps/edge/tests/route-authz.test.ts` covering:
- `loadGroupConversationForUser()` returns not-found when the conversation is not a group or RLS/user-client cannot see it.
- `loadGroupConversationForUser()` returns forbidden when service-role participant lookup does not contain the caller.
- `requireGroupRole()` allows `owner` / `admin` and rejects `member`.

Run: `bun --filter='@pendingbot/edge' run test -- tests/route-authz.test.ts`
Expected: FAIL because `../src/lib/route-authz` does not exist.

- [x] **Step 2: Implement `route-authz.ts`**

Add reusable functions:
- `loadGroupConversationForUser(env, userJwt, userId, conversationId)`
- `requireGroupRole(env, conversationId, userId, roles)`
- `listGroupAdminUserIds(env, conversationId)`
- `isGroupHumanParticipant(env, conversationId, userId)`

Return discriminated unions with HTTP-safe codes, not thrown exceptions.

- [x] **Step 3: Refactor routes**

Use the helper in `group-voice.ts` for `loadGroupContext`, admin id loading, and human participant checks. Use it in `groups.ts` for title/admin checks and invite admin checks.

- [x] **Step 4: Verify**

Run:
- `bun --filter='@pendingbot/edge' run test -- tests/route-authz.test.ts`
- `bun --filter='@pendingbot/edge' run test`
- `bun --filter='@pendingbot/edge' run typecheck`

### Task 2: Shared Voice Metering Primitive

**Files:**
- Create: `apps/edge/src/lib/voice-metering.ts`
- Test: `apps/edge/src/lib/voice-metering.test.ts`
- Modify: `apps/edge/src/durable-objects/realtime-meter.ts`
- Modify: `apps/edge/src/durable-objects/room-voice.ts`

- [x] **Step 1: Write failing tests**

Create tests for:
- cached text/audio usage is split into full-rate and cache-read buckets once.
- realtime event summaries never include `instructions`, raw `session`, or raw `response`.

Run: `bun --filter='@pendingbot/edge' run test -- src/lib/voice-metering.test.ts`
Expected: FAIL because `voice-metering.ts` does not exist.

- [x] **Step 2: Implement helper**

Move common usage splitting and safe event summarization into `voice-metering.ts`:
- `splitRealtimeUsage(usage)`
- `safeRealtimeEventSummary(msg)`
- `safeRealtimeErrorSummary(msg)`

- [x] **Step 3: Refactor DOs**

Use `splitRealtimeUsage` in both voice DOs before `computeVoiceCost`, and use safe summaries in `RealtimeMeterDO` logs.

- [x] **Step 4: Verify**

Run:
- `bun --filter='@pendingbot/edge' run test -- src/lib/voice-metering.test.ts tests/privacy-logging.test.ts`
- `bun --filter='@pendingbot/edge' run test`
- `bun --filter='@pendingbot/edge' run typecheck`

### Task 3: Close Existing Tech-Debt Status Drift

**Files:**
- Modify: `docs/tech-debt.md`
- Modify: `docs/security-audit-2026-05-24.md`

- [x] **Step 1: Update entries**

Mark the device-grant scope escalation entry resolved because `device-login.ts` now rejects scopes outside grant kind and outside original challenge request, with `device-login.test.ts` coverage.

- [x] **Step 2: Update architecture entries**

Change the service-role boundary and voice-metering entries from raw findings to partially fixed, naming the new helper modules and remaining route families that still need migration.

- [x] **Step 3: Verify docs**

Run `git diff --check`.

### Task 4: Message And Friend-Request Authorization Tightening

**Files:**
- Modify: `apps/edge/src/lib/route-authz.ts`
- Modify: `apps/edge/src/routes/messages.ts`
- Modify: `apps/edge/src/routes/friend-requests.ts`
- Modify: `apps/ios/PendingBot/Features/Group/GroupSettingsView.swift`
- Test: `apps/edge/tests/messages-recall.test.ts`
- Test: `apps/edge/tests/friend-requests.test.ts`
- Test: `apps/edge/tests/route-authz.test.ts`

- [x] **Step 1: Pin message delete boundary**

Add regression coverage that a group owner cannot hard-delete another human participant's message, while a user_bot conversation owner can still delete a bot reply presentation row.

- [x] **Step 2: Move delete authorization into helper**

Add `authorizeMessageDelete()` to `route-authz.ts` and use it from `DELETE /v1/messages/:id`.

- [x] **Step 3: Require source group for peer-id friend requests**

Change the peer-id add-friend path so a request by UUID must include `sourceConversationId`, and Edge verifies both users are human members of that group. Update iOS `GroupAddFriendSheet` to send the source group id.

- [x] **Step 4: Verify**

Run:
- `bun --filter='@pendingbot/edge' run test -- tests/messages-recall.test.ts tests/route-authz.test.ts`
- `bun --filter='@pendingbot/edge' run test -- tests/friend-requests.test.ts`

### Task 5: Bot Use Authorization Drift

**Files:**
- Modify: `apps/edge/src/lib/route-authz.ts`
- Modify: `apps/edge/src/routes/messages.ts`
- Test: `apps/edge/tests/route-authz.test.ts`

- [x] **Step 1: Add shared bot-use helper**

Add `authorizeBotUse()` so private creator checks and `public_invite` invite checks live in one helper.

- [x] **Step 2: Use helper on all paid message turns**

Use the helper from both normal message sends and regenerate. This closes the drift where normal sends rechecked revoked `public_invite` access but regenerate did not.

- [x] **Step 3: Verify**

Run:
- `bun --filter='@pendingbot/edge' run test -- tests/route-authz.test.ts tests/messages-recall.test.ts`
- `bun --filter='@pendingbot/edge' run typecheck`
