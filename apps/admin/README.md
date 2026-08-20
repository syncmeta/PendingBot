# @pendingbot/admin — admin console

Block 4 of the PendingBot dashboard stack: an Access-gated, audited **Refine**
SPA for internal admin work. Its static build is bundled into the edge Worker
and served same-origin under `/board`.

- **Framework:** [Refine](https://refine.dev) v5 (`@refinedev/core@5.0.12`),
  headless (no UI kit), `@refinedev/react-router@2.0.4` + `react-router@7`.
- **Bundler:** Vite (`vite build` → `dist/`).
- **Auth:** Cloudflare Access. The edge validates the Access JWT and then checks
  `BOARD_ADMIN_EMAILS`; there is no browser-side Supabase login or key.
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
cp .env.example .env     # one optional local edge URL override
bun install
bun run dev              # http://127.0.0.1:5174
```

## Env vars

The only client-exposed variable is prefixed `VITE_` (Vite inlines it at build
time via `import.meta.env`). Production needs no value because the board and
API share the Worker origin. Never put a Supabase secret key in this app.

| Var | Meaning |
|---|---|
| `VITE_EDGE_API_URL` | Optional local override, normally `http://127.0.0.1:8787`. Absent means same-origin. |

> CORS only matters for the separate local Vite server. The deployed board is
> same-origin and is protected by one Access application covering `/board*`
> and `/v1/board/*`.

## Build

```sh
bun run build            # tsc --noEmit && vite build → dist/
```

`dist/` is a static SPA. Wrangler uploads it as the edge Worker's `ASSETS`
binding and the Worker owns the SPA fallback under `/board`.

## Packaging

Build this app before `wrangler dev`; the Worker's assets configuration points
at `apps/admin/dist` and Wrangler refuses to start when that directory is
missing:

```sh
bun --filter='@pendingbot/admin' run build
bun --filter='@pendingbot/edge' run dev
```

Production deployment is deliberately not part of the self-hosting quickstart.
The edge package's deploy script builds this app before uploading both pieces.

## Resource → edge route map & known gaps

`src/providers/resource-map.ts` is the single source of truth for which edge
endpoints each page uses, and which **do not exist yet** (`exists: false`).
Pages backed by a pending endpoint render a warning banner and the call 404s —
no fake success. `resource-map.ts` itself is the gap list — read it there
rather than trusting this paragraph. Today only two edge surfaces exist and
are reused:

- `GET  /v1/human-help-requests` (requester-scoped) + `POST .../:id/decision`
- `POST /v1/permission-requests/:id/decide`

Everything else (admin reads for users/bots/conversations/billing, wallet
grant/claw-back, ledger adjust, account ops, admin-wide queues) is a pending
edge admin endpoint.
