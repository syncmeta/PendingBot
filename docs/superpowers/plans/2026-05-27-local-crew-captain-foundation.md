> ⚠️ **DEPRECATED — 2026-05-28**
>
> 这份 plan 已被 [`2026-05-28-v1-0-implementation-roadmap.md`](./2026-05-28-v1-0-implementation-roadmap.md)(roadmap T2.2 + T3.x)取代。保留作历史参考。后续 implementation 以新文件为准。

# Local Crew Captain Foundation Implementation Plan(已废弃)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first backend/API slice for local 机组: DAG parent links, captain representation, and responsibility-ratio inheritance.

**Architecture:** Keep `temporary_group_meta` as the existing Crew backing table for now, then layer explicit DAG edges and responsibility-ratio snapshots on top. Edge routes call database RPCs for mutations and read normalized rows for UI clients. PendingBot and PendingCrew consume the same contract.

**Tech Stack:** Supabase Postgres migrations/RPCs, Cloudflare Worker Hono routes, Vitest fake Supabase route tests, Swift API model follow-up.

---

### Task 1: Edge Contract Red Tests

**Files:**
- Modify: `apps/edge/tests/crew.test.ts`

- [ ] **Step 1: Add failing tests for child Crew creation and DAG reads**

Add tests that assert:

```ts
POST /v1/crew/:id/children
body: { title: "API 小组" }
calls create_child_crew_inheriting_responsibility with:
  p_parent_crew_conversation_id: "crew-parent"
  p_title: "API 小组"
returns { conversationId: "crew-child" }

GET /v1/crew/:id/links
returns parents, children, and responsibilityShares
```

- [ ] **Step 2: Run red test**

Run:

```bash
cd apps/edge
bun test tests/crew.test.ts
```

Expected: FAIL because the new routes do not exist.

### Task 2: Edge Route Implementation

**Files:**
- Modify: `apps/edge/src/routes/crew.ts`

- [ ] **Step 1: Add request schemas**

Add:

```ts
const CreateChildCrewBody = z.object({
  title: z.string().trim().min(1).max(80),
});
```

- [ ] **Step 2: Add child creation route**

Implement `POST /:id/children`:

- Requires `crew:write`.
- User auth calls `create_child_crew_inheriting_responsibility`.
- Device grant calls `create_child_crew_inheriting_responsibility_for_subject`.
- Maps forbidden to 403, not found to 404, invalid to 400.

- [ ] **Step 3: Add link read route**

Implement `GET /:id/links`:

- Requires `crew:read`.
- Returns:

```json
{
  "parents": [],
  "children": [],
  "responsibilityShares": []
}
```

Use normalized view names from Task 3.

- [ ] **Step 4: Run route tests**

Run:

```bash
cd apps/edge
bun test tests/crew.test.ts
```

Expected: PASS.

### Task 3: Supabase Migration

**Files:**
- Create: `supabase/migrations/20260527120000_crew_dag_captain_responsibility.sql`

- [ ] **Step 1: Add schema**

Create:

```sql
pendingbot.crew_parent_links
pendingbot.crew_responsibility_shares
```

Extend `temporary_group_meta` with:

```sql
captain_bot_id uuid null references pendingbot.bots(id),
runtime_kind text not null default 'local',
responsibility_mode text not null default 'inherit'
```

Extend `temporary_group_members.member_kind` to include `captain`, and add:

```sql
represents_crew_id uuid null references pendingbot.conversations(id)
```

- [ ] **Step 2: Add read helpers**

Add functions/views:

```sql
pendingbot.resolve_crew_responsibility_shares(p_crew_conversation_id uuid)
pendingbot.crew_link_summaries
```

The resolver returns rows `(subject_id, share_bps)` and uses explicit shares first, then inherited parent shares, then legacy `responsible_subject_id` as 100%.

- [ ] **Step 3: Add child creation RPCs**

Add:

```sql
pendingbot.create_child_crew_inheriting_responsibility(...)
pendingbot.create_child_crew_inheriting_responsibility_for_subject(...)
```

These create a child Crew, link it to the parent, create a captain placeholder when available, and do not create a new explicit responsibility split.

- [ ] **Step 4: Add grants and revoke broad execute**

Grant authenticated only where needed, service_role for device-grant RPCs.

### Task 4: Client Type Surface

**Files:**
- Modify: `apps/ios/PendingBot/Features/Crew/CrewAPI.swift`
- Modify: `apps/macos/PendingCrew/Sources/PendingCrew/Models/APIModels.swift`
- Modify: `apps/macos/PendingCrew/Sources/PendingCrew/Services/PendingBotAPI.swift`

- [ ] **Step 1: Add API models**

Add models for:

```swift
CrewLinkSummary
CrewResponsibilityShare
CrewLinksResponse
```

- [ ] **Step 2: Add methods**

Add:

```swift
crewLinks(crewId:)
crewCreateChild(crewId:title:)
```

No UI changes in this task.

### Task 5: Verification And Commit

**Files:**
- All files above

- [ ] **Step 1: Run checks**

Run:

```bash
cd apps/edge
bun test tests/crew.test.ts
swift test --package-path apps/macos/PendingCrew
git diff --check
```

- [ ] **Step 2: Commit**

```bash
git add apps/edge/tests/crew.test.ts apps/edge/src/routes/crew.ts supabase/migrations/20260527120000_crew_dag_captain_responsibility.sql apps/ios/PendingBot/Features/Crew/CrewAPI.swift apps/macos/PendingCrew/Sources/PendingCrew/Models/APIModels.swift apps/macos/PendingCrew/Sources/PendingCrew/Services/PendingBotAPI.swift docs/superpowers/plans/2026-05-27-local-crew-captain-foundation.md
git commit -m "feat: add local crew captain foundation"
```

---

## Self-Review

- Spec coverage: covers local Crew DAG, captain representation, and responsibility-ratio inheritance. It does not implement UI; that is the next plan slice.
- Placeholder scan: no TBD/TODO placeholders.
- Type consistency: route names, RPC names, and client method names are consistent across tasks.
