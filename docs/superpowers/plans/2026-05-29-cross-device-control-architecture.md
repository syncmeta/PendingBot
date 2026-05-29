# T4.5 — Cross-Device Session Control Architecture

> Status: foundation (P0) shipped — DO + WS protocol + route + offline queue + 11 vitest cases. This doc captures the as-built design and the multi-session roadmap that fills in client wiring (P1), zod hardening (P1+), and v1.1 Fly machine integration.
>
> Spec source: `docs/superpowers/specs/2026-05-28-pendingbot-pendingcrew-product-design-v2.md` §8.2 (Runtime Location — unified `peer_device` / `fly_machine` abstraction) + §9.6 (跨端遥控).

## 1. Why this exists

PendingBot (iPhone / iPad / Mac) and PendingCrew (Mac / iPad) are **account-synced**. The same logged-in account on any device must be able to:

1. Watch a session running somewhere else (status, progress, key events).
2. Send commands into that session's queue (`@session …`).
3. Approve or reject permission requests that pause the session.

The session itself runs on **exactly one** physical host — today PendingCrew Mac, in v1.1 a Fly machine. The spec deliberately collapses both into the same `peer_device` / `fly_machine` runtime-location abstraction so the comms layer can be one thing, not two.

That "one thing" is `SessionProxyDO` — a Cloudflare Durable Object instance keyed by `session_id` that holds the WebSockets for every device watching / controlling the session plus the single runner host actually executing it.

## 2. Topology

```
                                                     ┌──────────────────┐
  iPhone PendingBot   ─── wss ───┐                   │ runner host      │
  iPad PendingBot     ─── wss ───┤                   │ (PendingCrew Mac │
  Mac PendingBot      ─── wss ───┤                   │  today;          │
  iPad PendingCrew    ─── wss ───┼──▶ SessionProxyDO ◀── wss ───────────┤  Fly machine     │
                                  │   (one per       │                   │  in v1.1)        │
                                  │    session_id)   │                   └──────────────────┘
                                  │                  │
                                  └── persists ──▶  Supabase
                                       (session_mailbox,
                                        permission_requests)
```

- **Many viewers, at most one runner.** Newest runner connect wins (a reconnecting runner displaces the stale socket); viewers are additive.
- **DO is location-agnostic.** Whether the runner is a Mac at home or a Fly machine in a datacenter is irrelevant to the DO. v1.1 Fly only adds API integration + per-second billing on top of the same channel.
- **One DO instance per session, not per user / per device.** `SESSION_PROXY_DO.idFromName(sessionId)` gives the same DO to every peer of the same session — that's how fan-out works without an external pub-sub layer.

## 3. Auth model

Auth happens at the HTTP route (`apps/edge/src/routes/session-proxy.ts`) **before** the upgrade reaches the DO. The DO never re-parses a bearer token; it trusts request headers because only the worker can reach the DO's `fetch`.

| Caller | Role | Required scope / ACL |
|---|---|---|
| Device grant with `runner:write` whose `subject_id == session.responsible_subject_id` | runner | `runner:write` scope (only `pendingcrew_runner` / `pendingcrew_control` grants carry it) |
| Device grant with `crew:read` whose `subject_id == session.responsible_subject_id` | viewer | `crew:read` scope |
| Supabase JWT user where `can_view_temporary_group(crew_conversation_id, user_id) = true` | viewer | crew membership ACL |
| Supabase JWT user requesting `?role=runner` | **rejected** | runner is always a device-granted host, never a logged-in human |

The route stamps trusted facts onto forwarded headers:

- `X-Proxy-Role: viewer | runner`
- `X-Proxy-Session-Id: <uuid>`
- `X-Proxy-Subject: <subject uuid>` (when known)
- `X-Proxy-User-Id: <user uuid>` (when known)

The DO reads those and rejects any subscribe frame whose claimed role doesn't match the authorized one (defence in depth — a compromised viewer client can't lie its way into runner privileges).

## 4. Protocol

Defined in `apps/edge/src/lib/session-proxy-protocol.ts`. JSON-framed, every frame discriminated by `type`.

### 4.1 Client → DO

| `type` | Sender | Purpose |
|---|---|---|
| `subscribe` | any | First frame after socket open. Echoes `role`; DO rejects role mismatch. |
| `session.command` | viewer (typical) | Command targeted at the runner. DO assigns `commandId` if absent. |
| `permission.decision` | viewer | Approve / reject a paused action. |
| `session.state` | runner | State update (status / progress / lastEvent). Fanned out to viewers. |
| `permission.request` | runner | High-risk action pause; fanned out to viewers + persisted. |

### 4.2 DO → client

| `type` | Receiver | Purpose |
|---|---|---|
| `subscribed` | any | Ack of subscribe. |
| `session.command` (deliver) | runner | Command delivered live or flushed from offline queue. `queued: true` marks offline-flush. |
| `session.command.ack` | sender | `delivered` (live) or `queued` (runner offline). |
| `session.state` | viewers | Fan-out of runner's state. |
| `permission.request` | viewers | Fan-out of runner's pause. |
| `permission.decision` (deliver) | runner | Routed decision so runner can unblock the paused action. |
| `error` | any | `bad_message`, `role_mismatch`, `forbidden`, `invalid_*`, `command_not_persisted`, `decision_not_persisted`. |

### 4.3 Validation

P0 ships a hand-written `parseClientMessage(raw)` that returns the typed message or `null` for garbage. **Roadmap P1+**: migrate to zod schemas so the discriminated union has runtime payload validation, not just type-tag matching. Zod is already a dep (used in `routes/envelope.ts` etc.) — straight swap, no new deps. Tracking the upgrade as a P1 follow-up rather than blocking P0 because:

- `parseClientMessage` already filters unknown `type` values.
- Per-message field validation today is inline in the handlers (`handleCommand` checks `kind`, `handlePermissionRequest` checks `action`, etc.).
- Zod refactor is purely defensive — no behavior change — so it can land independently without coordinating with iOS / Mac client work.

## 5. Persistence — durable mailbox is the source of truth

The WebSocket is the **fast path**; the durable mailbox is the **authoritative** path. Every command goes both places.

| Action | Live path | Durable path |
|---|---|---|
| Viewer sends `session.command` | Forward to runner socket; ack `delivered` | `enqueue_session_mailbox` RPC (`message_kind = 'instruction'`, payload `{ source: 'cross_device_remote', command_kind, command_payload }`) |
| Runner offline → command | Push to DO `offlineCommandQueue` (cap 500, oldest dropped) | Same mailbox RPC |
| Runner reconnects | Flush queue with `queued: true` | Runner's inbox-pull (T4.1) is the backstop — it sees the mailbox row regardless of DO state |
| Runner publishes `permission.request` | Fan to viewers | `create_permission_request` RPC (T4.3) returns canonical `request.id` |
| Viewer publishes `permission.decision` | Route to runner + fan to other viewers | `decide_permission_request` RPC (T4.3) — re-checks ACL against deciding user |

Failure modes are explicit:

- **Mailbox persist fails AND runner online**: live delivery still happens; only a warn-log records the gap (the runner got it, the durable backstop didn't). Acceptable because the runner's local state is now ahead of the mailbox — next runner-state publish or restart triggers an inbox pull that's a no-op on the missing row.
- **Mailbox persist fails AND runner offline**: explicit `error: command_not_persisted` frame back to the sender, command still queued in volatile DO state. The sender knows not to assume durability.
- **Decision persist fails**: `error: decision_not_persisted` back to the decider; live routing to runner still proceeds so the paused action can unblock. The DB just has a stale "pending" row that next list-fetch reconciles.

## 6. Offline queue — bounded, durable, idempotent

- Stored under DO storage key `offlineCommandQueue` so a DO eviction + revival doesn't lose it.
- `MAX_OFFLINE_QUEUE = 500`. Past the cap, oldest entries drop. The durable mailbox is the authoritative backstop; the runner's inbox pull reconstructs anything dropped from the in-memory queue.
- `queueLoaded` lazy flag — storage hit happens on first enqueue / first runner reconnect, not on every DO instantiation.
- Flush drains in FIFO order and tags each delivered frame with `queued: true` so the runner can dedupe / order against its own state (e.g. it may already have processed some of those via mailbox inbox-pull).

## 7. Files

| Path | Purpose |
|---|---|
| `apps/edge/src/durable-objects/session-proxy.ts` | `SessionProxyDO` class — socket lifecycle, message router, offline queue, persistence calls. |
| `apps/edge/src/lib/session-proxy-protocol.ts` | Protocol types + `parseClientMessage`. (P0 plain TS; P1+ zod swap.) |
| `apps/edge/src/routes/session-proxy.ts` | `/v1/sessions/:sessionId/proxy/connect` WS upgrade route — auth + ACL + role resolution + forward to DO. |
| `apps/edge/wrangler.jsonc` | `SESSION_PROXY_DO` binding + `v7` migration (`new_sqlite_classes: ["SessionProxyDO"]`). |
| `apps/edge/src/types.ts` | `SESSION_PROXY_DO: DurableObjectNamespace` on `Env`. |
| `apps/edge/src/index.ts` | `export { SessionProxyDO }`; `v1.route('/sessions', sessionProxyRoutes)`. |
| `apps/edge/tests/session-proxy.test.ts` | 11 vitest cases driving the message router with a fake DO state + fake socket. |

> **Note on directory layout.** The original task brief suggested `apps/edge/src/lib/session-proxy/SessionProxyDO.ts`. The codebase puts the DO class under `src/durable-objects/` (matching `RoomVoiceDO`, `RealtimeMeterDO`, `RoomMediaContainerDO`, `GroupRouterDO`, `RealtimeHubDO`) and the wire-format types under `src/lib/`. Both placements are consistent with existing conventions, so we matched the conventions rather than introducing a one-off layout.

## 8. Roadmap

### P1 — client wiring (separate sessions)

- **PendingCrew Mac runner client**: open `/v1/sessions/:id/proxy/connect?role=runner` with a `pendingcrew_runner` device grant; subscribe, handle `session.command` (live + queued flush) by enqueueing into the local claude-code / codex prompt queue; emit `session.state` on local state transitions; emit `permission.request` when the agent hits a high-risk pause; consume `permission.decision` to unblock.
- **iOS / iPadOS / Mac PendingBot viewer client**: open with `?role=viewer` (no `?role` defaults to viewer); render `session.state` into the session detail view; render `permission.request` cards inline in the crew chat (already shipped — see commit `f18a9a6c`); send `session.command` when the user types into the session composer; send `permission.decision` from the approve/reject buttons.
- **iPad PendingCrew viewer client**: same WS shape as PendingBot viewer, scoped to the iPad's account's crews.

### P1+ — zod schemas

Migrate `parseClientMessage` to a zod discriminated union (`z.discriminatedUnion('type', [...])`). Inline field checks in handlers (`kind` non-empty, `action` non-empty, etc.) move to the schema. Same wire format, stronger guarantees.

### v1.1 — Fly machine runtime location

Spec §8.2 says `fly_machine` reuses this exact channel. The integration adds:

- A "boot a Fly machine for this session" path that provisions the runner host on demand instead of using an already-online Mac.
- The Fly machine connects back to the same `/v1/sessions/:id/proxy/connect?role=runner` with a generated device grant.
- Per-second billing meter (Fly machine uptime → wallet debit on `responsible_subject_id`).
- No DO / protocol changes required. That's the whole point of the unified abstraction.

### Future — hibernation + WebSocketPair upgrade

Current DO uses the `accept() + addEventListener` pattern (matching `RoomVoiceDO` / `RealtimeMeterDO`). Hibernation API (`acceptWebSocket`) is a fine future optimization once we have signal that idle DOs are a real cost — but adopting it now would diverge from the two reference DOs without a measured win. Defer until traffic justifies.

## 9. Open questions / risks

- **DO eviction during a long runner-offline window.** Bounded by `MAX_OFFLINE_QUEUE = 500` + durable mailbox backstop. If a session sits idle for days with hundreds of queued commands, the DO will evict and the offline queue will be reconstructed only from the mailbox on next connect — which is fine but means `queued: true` ordering may differ from the original enqueue order. The runner needs to be order-agnostic when applying queued commands (it should be anyway — see "dedupe / order against its own state").
- **Single-runner assumption.** Newest-wins displacement assumes the previous runner is dead, not just briefly disconnected. A Mac that flaps wifi could lose its socket to a delayed reconnect from itself. Acceptable for v1 (rare); if it becomes a problem add a runner-side "I'm still here" heartbeat with a debounce on the DO side.
- **Multi-machine same-account runner race.** If a user has two PendingCrew Macs both with `runner:write` device grants for the same session, both could try to be runner. The DO only routes commands to one at a time (newest wins) but the displaced Mac may still be running the agent locally → split brain. v1 ignores this (one user, one PendingCrew Mac is the assumed deployment); v1.1 / multi-host is a future T4.6.
