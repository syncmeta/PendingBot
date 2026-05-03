# Supabase

Supabase project for PendingBot. Local dev mirrors what the staging / prod hosted projects look like. Schema lives in `migrations/0001_init.sql` (a single consolidated baseline); seed data in `seeds/`.

## Quick start

```bash
# 1. Install Supabase CLI
brew install supabase/tap/supabase

# 2. Start local stack (Postgres, Auth, Realtime, Studio)
supabase start

# 3. Apply migrations
supabase db reset

# 4. Studio: http://localhost:54323

# 5. Link to remote (one of these per env)
supabase link --project-ref <staging-id>     # for staging
supabase link --project-ref <prod-id>        # for prod
supabase db push                              # push migrations to linked remote
```

## Layout

- `config.toml` — local dev stack config (ports, schemas exposed via API, seed paths).
- `migrations/0001_init.sql` — consolidated baseline. From now on this is the only schema migration; new changes go in additive `0002_…sql`, `0003_…sql`, never edit `0001`.
- `seeds/` — auto-applied by `supabase db reset` after migrations, in the order listed under `[db.seed]` in `config.toml`. Each file is idempotent (`ON CONFLICT`).

## How the baseline was built

`0001_init.sql` is a `pg_dump --schema-only --schema=pendingbot` of the database after the original 19-step migration chain (0001..0019) was applied to a fresh Postgres, plus the cross-schema bits the dump can't see (auth.users trigger, realtime publication, schema grants). Seed data was carved out into `seeds/`. The original chain — including its patches-on-patches (delete_self_account redone 4×, RLS recursion fix, preset bot list redone 3×) — is in git history before the squash commit if you ever need it.

## Schema namespace

Business tables live under `pendingbot.*` (not `public.*`) so future products can share the same Supabase project's `auth.users` while keeping their data separate.
