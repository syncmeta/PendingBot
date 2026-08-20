-- Introspect SECURITY DEFINER functions that anon / PUBLIC can execute.
--
-- Feeds `bun scripts/definer-execute-gate.ts`. Read-only: safe to run against
-- the linked production database (`supabase db query --linked -o json -f ...`).
--
-- Why this matters: a SECURITY DEFINER function runs as the database owner and
-- bypasses RLS. Postgres grants EXECUTE on new functions to PUBLIC by default,
-- so a migration that writes `grant execute ... to service_role` but forgets
-- `revoke execute ... from public` silently publishes a privileged endpoint at
-- /rest/v1/rpc/<name>. That is exactly how upsert_self_machine ended up
-- callable without a login (fixed in
-- 20260820073931_revoke_public_execute_upsert_self_machine.sql).
--
-- Scope: the schemas PostgREST exposes, i.e. `[api] schemas` in
-- supabase/config.toml. Supabase-managed schemas (auth, storage, extensions,
-- graphql, realtime) are deliberately out of scope — we do not own their
-- grants, and including them would bury our own regressions in vendor noise.

select
  n.nspname                                        as schema,
  p.proname                                        as function,
  pg_get_function_identity_arguments(p.oid)        as args,
  has_function_privilege('anon', p.oid, 'EXECUTE') as anon_execute,
  case
    when p.proacl is null then true  -- NULL acl == built-in default == EXECUTE TO PUBLIC
    else exists (
      select 1 from aclexplode(p.proacl) a
       where a.grantee = 0 and a.privilege_type = 'EXECUTE'
    )
  end                                              as public_execute,
  has_schema_privilege('anon', n.oid, 'USAGE')     as anon_schema_usage,
  coalesce(p.proacl::text, '(default: EXECUTE TO PUBLIC)') as acl
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where p.prosecdef
  and n.nspname in ('public', 'graphql_public', 'pendingbot')
  and (
    has_function_privilege('anon', p.oid, 'EXECUTE')
    or p.proacl is null
    or exists (
      select 1 from aclexplode(p.proacl) a
       where a.grantee = 0 and a.privilege_type = 'EXECUTE'
    )
  )
order by 1, 2, 3;
