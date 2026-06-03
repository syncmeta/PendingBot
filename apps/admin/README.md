# @pendingbot/admin — admin console

Block 4 of the PendingBot dashboard stack: a login-gated, audited **Refine** SPA
for internal admin work. Static build → **Cloudflare Pages**.

- **Framework:** [Refine](https://refine.dev) v5 (`@refinedev/core@5.0.12`),
  headless (no UI kit), `@refinedev/react-router@2.0.4` + `react-router@7`.
- **Bundler:** Vite (`vite build` → `dist/`).
- **Auth:** Supabase Auth (email/password → JWT). The JWT is attached as a
  `Bearer` token to every edge call; the edge (`packages/identity` →
  `requireSession`) verifies it.
- **Data:** a **custom dataProvider** that talks ONLY to the edge REST API
  (`<EDGE>/v1/*`). **No direct Postgres access; no service-role key in the
  browser.** Business rules + audit live in edge.

## Why edge-only (not @refinedev/supabase)

The dashboard spec requires every write to pass through edge so business rules
and `admin_audit` are enforced. So we do NOT use `@refinedev/supabase` /
`ra-data-postgrest` (which hit Postgres directly). The dataProvider
(`src/providers/data-provider.ts`) maps each Refine resource to an edge route
via `src/providers/resource-map.ts`.

## Local dev

```sh
cp .env.example .env     # fill in the three VITE_ vars
bun install
bun run dev              # http://127.0.0.1:5174
```

## Env vars

All client-exposed, prefixed `VITE_` (Vite inlines them at build time via
`import.meta.env`). Set the SAME keys as **Cloudflare Pages → Settings →
Environment variables** for prod. None are secrets in the service-role sense —
the Supabase anon key is RLS-gated and safe in the browser. **Never** put
`SUPABASE_SERVICE_ROLE_KEY` here.

| Var | Meaning |
|---|---|
| `VITE_EDGE_API_URL` | Edge origin, e.g. `https://bot.pendingname.com`. Routes are `<base>/v1/*`. |
| `VITE_SUPABASE_URL` | Supabase project URL (for Auth only). |
| `VITE_SUPABASE_ANON_KEY` | Supabase anon/public key (Auth only). |

> CORS: the edge locks `ALLOWED_ORIGIN` to a single origin
> (`apps/edge/wrangler.jsonc`). The deployed Pages origin must be added there,
> or browser calls from the console will be blocked.

## Build

```sh
bun run build            # tsc --noEmit && vite build → dist/
```

`dist/` is a static SPA. `public/_redirects` (`/* /index.html 200`) gives
client-side routing its SPA fallback on Pages.

## Deploy to Cloudflare Pages

First time only, create the Pages project:

```sh
bunx wrangler pages project create pendingbot-admin
```

Then deploy the build output (this is what `bun run deploy` runs):

```sh
bunx wrangler pages deploy dist --project-name=pendingbot-admin
```

(Do not auto-deploy on merge — deploys are deliberate and user-initiated.)

## Resource → edge route map & known gaps

`src/providers/resource-map.ts` is the single source of truth for which edge
endpoints each page uses, and which **do not exist yet** (`exists: false`).
Pages backed by a pending endpoint render a warning banner and the call 404s —
no fake success. The full gap list is logged in `docs/tech-debt.md` (search
"admin console"). Today only two edge surfaces exist and are reused:

- `GET  /v1/human-help-requests` (requester-scoped) + `POST .../:id/decision`
- `POST /v1/permission-requests/:id/decide`

Everything else (admin reads for users/bots/conversations/billing, wallet
grant/claw-back, ledger adjust, account ops, admin-wide queues) is a pending
edge admin endpoint.
