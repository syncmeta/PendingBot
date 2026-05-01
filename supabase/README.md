# Supabase

Supabase project for PendingBot. Local dev mirrors what the staging / prod hosted projects look like. Schema migrations live in `migrations/`; B1 lands `0001_init.sql`.

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

- `config.toml` — local dev stack config (ports, schemas exposed via API, etc.)
- `migrations/` — SQL files applied in filename order; never edit a committed one (only add new)
- `seeds/` — optional seed data for local dev only

## Schema namespace

Business tables live under `pendingbot.*` (not `public.*`) so future products can share the same Supabase project's `auth.users` while keeping their data separate. See `.claude/plans/pendingbot-rewrite/04-schema-and-sync.md`.
