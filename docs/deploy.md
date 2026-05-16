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
bunx wrangler secret put WORLDROUTER_API_KEY --env production
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
3. **Push the migration** — `supabase db push --linked` applies
   `..._realtime_webhooks.sql`, which installs the pg_net triggers on
   the six realtime tables. From this point row changes fan out to the
   hub.
4. **iOS** already cuts over on the next build — `RealtimeManager` /
   `ScrollFeedChannel` connect to the hub, no flag.

Verify on-device: messages, unread badges, scroll-feed and group
continue-requests all update live; check `net._http_response` in
Postgres for failed webhook POSTs.

Rollback is `git revert` of the realtime commits + redeploy — the
Supabase Realtime publication is intentionally left intact, so the old
client path still works until it's deliberately removed.

Only **after** verification: drop the now-dead `supabase_realtime`
publication membership and the unused `messages.content_partial`
column (it backed a streaming design that was never wired).

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
