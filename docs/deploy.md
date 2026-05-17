# Deploy recipe

Pointed at by `CLAUDE.md`'s short Deploys section. Read this only when
the session is actually about deploying — it's not in the auto-loaded
project doc to keep every session's context lean.

Three deployable surfaces. **Each one is operator-initiated** — never
auto-deploy on merge.

---

## Edge worker (`apps/edge/`)

Cloudflare Workers, lives at `api.pendingname.com` via custom domain.
Single deployed env (`env.production` in `wrangler.jsonc`); local
iteration uses `wrangler dev`.

```sh
bun --filter='@pendingbot/edge' run deploy
```

The `--filter='...'` form (with `=`) matters — bun ≥ 1.3 silently
mis-parses `--filter @pendingbot/edge` (space-separated) as no-match.

### Secrets

Bound per-env via `wrangler secret put`. **Always pass
`--env production`** — without that flag the secret goes to a
default/dev env the deployed prod worker can't see, and
`resolveRoute()` throws `NoRouteError` because the env var lookup
misses.

```sh
cd apps/edge
bunx wrangler secret put CF_AIG_RUN_TOKEN --env production
```

Verify what's bound:

```sh
bunx wrangler secret list --env production
```

We hit this once already (added `WORLDROUTER_API_KEY` without
`--env production`; iOS messages went to `bot-reply`, route resolved
to WR alias, env lookup missed, NoRouteError, fallback to OR — fix
was re-putting with the flag).

---

## iOS (`apps/ios/`)

TestFlight via the configured ASC API key (see user memory). Driven
by Xcode's archive flow + `xcodebuild -exportOptionsPlist`. Out of
scope for most agent sessions.

---

## Board (`apps/board/`) — internal admin UI

Next.js 15. **Currently NOT deployed** — runs locally only.
Pre-launch single-user ops doesn't need a hosted instance; one
`bun run dev:board` from the worktree is the entire UI surface.

```sh
bun run dev:board
# → http://localhost:4000
```

### Pointing local Board at prod data

Populate `apps/board/.env.local` with prod URL + keys (gitignored,
never commits):

```sh
supabase projects api-keys --project-ref <prod-ref>
# pipe anon + service_role into apps/board/.env.local
# see apps/board/.env.example for shape
```

Then restart the dev server. Login still requires
`pendingbot.users.is_admin = true` for the auth.uid().

### When eventually deploying

Natural target: **Cloudflare Pages with `@opennextjs/cloudflare`**
(matches the existing CF stack). Domain not decided.

Steps when picked:
1. `bun add -d @opennextjs/cloudflare` in `apps/board/`
2. Add `wrangler.jsonc` + `open-next.config.ts` under `apps/board/`
3. Build: `opennextjs-cloudflare build`
4. Deploy: `opennextjs-cloudflare deploy`
5. CF Pages env vars need both Supabase keys + a real (non-localhost)
   `NEXT_PUBLIC_SUPABASE_URL`

---

## After-merge checklist

When `feat/*` lands on `main`, decide which deploys are needed:

| Files changed | Action |
|---|---|
| `apps/edge/src/**`, `apps/edge/wrangler.jsonc`, `apps/edge/src/types.ts` | Run edge deploy |
| New `supabase/migrations/00NN_*.sql` | `supabase db push --linked` against prod, then regen `apps/edge/src/db/schema.ts` and re-typecheck |
| `apps/board/**` source | If local dev server is running, hot-reload picks it up. If Board ever gets deployed, redeploy. |
| Pure prod data (direct SQL like flipping `model_id` / `is_admin`) | No deploy. Ephemeral state, won't survive a `supabase db reset` if anyone ever runs that on prod (we don't, single-env). |

---

## Supabase CLI gotcha across worktrees

`supabase link` writes `supabase/.temp/project-ref` +
`linked-project.json` in the cwd's worktree. **Other worktrees don't
inherit the link.** When operating from a feat worktree, copy from
the main worktree if `supabase db query --linked` complains
"Cannot find project ref":

```sh
cp /path/to/main/supabase/.temp/{project-ref,linked-project.json,pooler-url,*-version} \
   ./supabase/.temp/
```

---

## LLM seed (`apps/board/scripts/seed-llm-dev.sql`)

Not a migration — applies the canonical model + alias catalog
separately because pricing changes more often than schema and
shouldn't pollute migration history.

Apply to local DB:

```sh
docker exec -i supabase_db_pendingbot psql -U postgres -d postgres \
  < apps/board/scripts/seed-llm-dev.sql
```

Apply to prod DB:

```sh
supabase db query --linked -f apps/board/scripts/seed-llm-dev.sql
```

Idempotent (`ON CONFLICT DO NOTHING`); rerun freely. Editing the
file's UPDATEs is the cleaner way to bump prices vs writing a
migration.

---

## Realtime cutover (Supabase Realtime → CF hub)

Realtime delivery runs over Cloudflare: clients hold WebSockets to the
`RealtimeHubDO` (`apps/edge/src/durable-objects/hub.ts`); the database
fans row changes in via pg_net webhooks → `POST /v1/realtime-internal/
notify` → the DO. Supabase Realtime is no longer used by the iOS app.

The pieces span three deploys that **must go together** — the webhook
migration POSTs into the Worker, so the Worker must carry the notify
route before the triggers exist.

1. **Pick a shared secret** (any long random string), then:
   - Worker: `wrangler secret put REALTIME_WEBHOOK_SECRET --env production`
   - Supabase Vault (so the pg_net trigger can read it):
     ```sh
     supabase db query --linked \
       "select vault.create_secret('<value>', 'realtime_webhook_secret');"
     ```
     The names must match: trigger looks up `realtime_webhook_secret`,
     Worker compares against `REALTIME_WEBHOOK_SECRET`.
2. **Deploy the Worker** — `bun --filter='@pendingbot/edge' run deploy`.
   This publishes the `REALTIME_HUB` DO (migration tag `v3`), the
   `/v1/realtime-hub/*` WebSocket routes, and the notify route.
3. **Push the migrations** — `supabase db push --linked` applies, in
   order:
   - `..._realtime_webhooks.sql` — installs the pg_net triggers on the
     six realtime tables. From here row changes fan out to the hub.
   - `..._drop_supabase_realtime.sql` — drops every pendingbot table
     from the `supabase_realtime` publication and drops the dead
     `messages.content_partial` column. (The iOS client no longer uses
     Supabase Realtime, so this is a clean teardown, not a staged one.)
4. **iOS** already cuts over on the next build — `RealtimeManager` /
   `ScrollFeedChannel` connect to the hub, no flag.

Verify on-device: messages, unread badges, scroll-feed and group
continue-requests all update live; check `net._http_response` in
Postgres for failed webhook POSTs.

Rollback is `git revert` of the realtime commits + redeploy the Worker;
re-add the publication membership by hand if needed (the teardown
migration removed it). There is no shadow-run — the cutover replaces
Supabase Realtime outright.

---

## AI Gateway cutover (BYOK-on-gateway + voice metering)

Branch `feat/ai-gateway-cutover`. Moves LLM provider auth onto the
Cloudflare AI Gateway (BYOK — provider keys live in the gateway
dashboard, not worker env) and replaces client-reported voice billing
with server-side metering.

### Dashboard prereqs (one-time, outside code — already done)

- A CF API token with **AI Gateway Read + Edit** is set as the worker
  secret `CF_AIG_RUN_TOKEN`. The worker sends it as `cf-aig-authorization`
  on every LLM request and on the voice sideband.
- **OpenRouter** key stored in the AI Gateway dashboard (BYOK / Store
  Keys, `default` alias). The worker no longer holds `OPENROUTER_API_KEY`
  for inference — that secret was deleted.
- **OpenAI** left OUT of BYOK Store Keys, so OpenAI inference falls to
  Unified Billing (CF credits). Voice realtime still uses the worker's
  `OPENAI_API_KEY` — that path is OpenAI-direct, not Unified Billing.

### Deploy order — Worker BEFORE the migration

The migration drops `llm_providers.secret_ref` / `auth_type`. The new
worker doesn't select those columns so it runs fine against the old
schema; the *old* worker breaks once they're gone. So:

1. **Deploy the Worker** — `bun --filter='@pendingbot/edge' run deploy`.
   Publishes BYOK `buildClient`, the new `RealtimeMeterDO` (DO migration
   tag `v4`), and the reworked `/v1/realtime/*` routes (`/usage` removed,
   `/attach` + `/ws` added).
2. **Apply the migration** — `supabase db push --linked` applies
   `20260516142651_byok_on_gateway.sql` (drops `secret_ref`/`auth_type`,
   removes the never-wired worldrouter provider + its aliases).
   `apps/edge/src/db/schema.ts` was already hand-edited to the
   post-migration shape (committed) — no regen needed; just re-typecheck.
3. **Board** — not deployed (local dev only); the local server picks up
   the provider-form changes after the branch merges.

### iOS — must ship a matching build

The worker removed `/v1/realtime/usage`; an old iOS build calling it
gets a 404 and voice turns stop being billed. The iOS build must:
- send `transport` (`webrtc` | `websocket`) on `POST /v1/realtime/session`;
- webrtc: after the WebRTC SDP exchange, `POST /v1/realtime/attach` with
  the `call_id`;
- websocket: open `wss://api.pendingname.com/v1/realtime/ws?session_id=…`
  and speak the realtime JSON protocol (audio as base64-in-JSON);
- stop calling `/v1/realtime/usage`.

### After cutover

Retune `billing_config.markup` from the Board — the old value was set
for WorldRouter (~0.7× OpenRouter) pricing, which no longer applies.

### Verify

- Text chat still routes (BYOK OpenRouter + Unified Billing OpenAI);
  `audit_log.cost_credits` is non-zero.
- A voice call on each transport writes per-turn `audit_log` rows with
  `task_type='voice_call'` and audio token counts.
- **Open question** — whether the AI Gateway forwards the `?call_id=`
  query param on the sideband WS. If webrtc voice turns aren't metered,
  the gateway isn't passing it through: in `realtime-meter.ts`
  `realtimeUrl()`, drop the gateway branch so the sideband connects
  straight to `api.openai.com` (billing still works direct).

### Rollback

`git revert` the branch + redeploy the worker. The migration's DROP
COLUMN is not cleanly reversible — re-add `secret_ref`/`auth_type` by
hand if a real rollback is needed (pre-launch, low stakes).

---

## Common gotchas

- **Port 4000 EADDRINUSE on `bun run dev:board`** → an old `next dev`
  is still running. `lsof -i :4000` finds the PID; `kill <pid>` frees
  it.
- **Worktree missing `node_modules`** → fresh worktree (or after a
  `bun install` run elsewhere) doesn't share with siblings. Run
  `bun install` from the worktree root.
- **`.env.local` doesn't follow git renames** → if `apps/admin/`
  becomes `apps/board/` via `git mv`, the gitignored `.env.local`
  stays in the OS-level rename target only if the parent `mv`
  succeeded. Verify after merging into another worktree:
  `mv apps/admin/.env.local apps/board/.env.local && rm -rf apps/admin`.
