// ─────────────────────────────────────────────────────────────────────────
// Resource → edge endpoint map.
//
// HARD RULE (dashboard spec): all reads AND writes go through the edge API,
// never direct-to-Postgres. So every Refine resource maps to an edge route
// here. The dataProvider (./data-provider.ts) consults this table to build
// the request for each (resource, action) pair.
//
// EXISTING vs PENDING — this is the load-bearing honesty of this file:
//
//   `exists: true`   → the edge route is mounted TODAY (verified against
//                      apps/edge/src/index.ts + the route file). Wired live.
//
//   `exists: false`  → the edge route does NOT exist yet. We point at the
//                      INTENDED path so the console is ready the moment the
//                      endpoint lands, but a call will currently 404. Every
//                      such gap is logged in docs/tech-debt.md (🟡). We do
//                      NOT fabricate a fake-working stub.
//
// As of this commit the edge has NO admin route surface at all (no
// /v1/admin/* is mounted; users.is_admin exists but `requireAdmin` from
// @pendingbot/identity is unused). Two routes the console reuses DO exist and
// are user-scoped, not admin-scoped:
//   - GET  /v1/human-help-requests          (status filter; requester-scoped)
//   - POST /v1/permission-requests/:id/decide
// Everything else the admin console needs is a pending admin endpoint.
// ─────────────────────────────────────────────────────────────────────────

export type ResourceRoute = {
  // Base path under the edge origin, no leading /v1 (the dataProvider adds it).
  // e.g. 'admin/users' → GET <EDGE>/v1/admin/users
  basePath: string;
  // Whether the edge route is mounted today. false = pending (will 404).
  exists: boolean;
  // Which list-shaped response key the edge returns the array under, if it is
  // NOT the standard `{ data, total }`. The dataProvider normalises these.
  // Most existing edge list routes return `{ items: [...] }`.
  listKey?: string;
  // Human note surfaced in code + tech-debt.
  note?: string;
};

export const RESOURCE_ROUTES: Record<string, ResourceRoute> = {
  // 1. Users (list/show) — id, handle, created_at, subject.
  users: {
    basePath: 'admin/users',
    exists: false,
    listKey: 'items',
    note: 'PENDING admin read endpoint: GET /v1/admin/users (+ /v1/admin/users/:id).',
  },

  // 2. Bots (list/show) — visibility, model, owner.
  bots: {
    basePath: 'admin/bots',
    exists: false,
    listKey: 'items',
    note: 'PENDING admin read endpoint: GET /v1/admin/bots (+ /:id). The existing /v1/bots routes are user-scoped, not an admin list.',
  },

  // 3. Conversations (list/show).
  conversations: {
    basePath: 'admin/conversations',
    exists: false,
    listKey: 'items',
    note: 'PENDING admin read endpoint: GET /v1/admin/conversations (+ /:id).',
  },

  // 4. Billing ledger — the spec calls it pnc_ledger; the actual table is
  //    pendingbot.billing_ledger (topups/refunds/consumption per user) +
  //    subject_wallets for per-subject balances. Read-only.
  billing_ledger: {
    basePath: 'admin/billing/ledger',
    exists: false,
    listKey: 'items',
    note: 'PENDING admin read endpoint: GET /v1/admin/billing/ledger. NB: spec name "pnc_ledger" does not exist in schema; real table is billing_ledger.',
  },

  // 5. Group pool / pledge view (read).
  group_pool: {
    basePath: 'admin/billing/group-pool',
    exists: false,
    listKey: 'items',
    note: 'PENDING admin read endpoint: GET /v1/admin/billing/group-pool. No pool/pledge view exists in schema; closest source tables are group_billing_config + group_member_billing.',
  },

  // 7a. Human-help-request queue — EXISTING route, user/requester-scoped.
  //     GET /v1/human-help-requests?status=pending|accepted|declined
  //     Returns { items: [...] }. The console reuses this read; an
  //     admin-wide variant (all requesters) is a pending gap noted below.
  human_help_requests: {
    basePath: 'human-help-requests',
    exists: true,
    listKey: 'items',
    note: 'EXISTING but requester-scoped (filters by requested_user_id = caller). Admin-wide queue (all requesters) needs GET /v1/admin/human-help-requests — PENDING.',
  },

  // 7b. Permission-request approvals — the LIST is a pending admin read;
  //     the DECIDE action EXISTS (POST /v1/permission-requests/:id/decide).
  permission_requests: {
    basePath: 'permission-requests',
    exists: false, // list is pending; decide action exists (handled in dataProvider.custom/update)
    listKey: 'items',
    note: 'DECIDE action EXISTS: POST /v1/permission-requests/:id/decide {decision: approve|reject}. LIST is PENDING: GET /v1/admin/permission-requests.',
  },
};

// 6. Admin actions (wallet grant / claw-back + pnc_ledger adjustment, account
//    ops). These are WRITES via edge. None exist yet — all PENDING. The
//    dataProvider.custom() targets these intended paths; the action pages POST
//    to them. Logged to tech-debt.
export const ADMIN_ACTION_ENDPOINTS = {
  // POST { subject_id | user_id, delta_credits, reason } → wallet credit grant
  walletGrant: { method: 'POST' as const, path: 'admin/billing/wallet/grant', exists: false },
  // POST { subject_id | user_id, delta_credits, reason } → claw-back (negative delta)
  walletClawback: { method: 'POST' as const, path: 'admin/billing/wallet/clawback', exists: false },
  // POST { user_id|subject_id, delta_credits, entry_type, reason } → direct ledger adjustment
  ledgerAdjust: { method: 'POST' as const, path: 'admin/billing/ledger/adjust', exists: false },
  // POST { user_id, op: 'freeze'|'unfreeze'|'delete' } → account ops
  accountOp: { method: 'POST' as const, path: 'admin/users/account-op', exists: false },
};

export function routeFor(resource: string): ResourceRoute {
  const r = RESOURCE_ROUTES[resource];
  if (!r) {
    throw new Error(`[admin] no edge route mapped for resource "${resource}"`);
  }
  return r;
}
