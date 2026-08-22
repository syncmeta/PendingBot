-- Introspect SECURITY DEFINER functions that are reachable without the caller
-- being checked. Read-only: safe against the linked production database
-- (`supabase db query --linked -o json -f ...`). Feeds
-- `bun scripts/definer-execute-gate.ts`.
--
-- A SECURITY DEFINER function runs as the database owner and bypasses RLS, so
-- who may call it — and whether it looks at who called it — is the whole of its
-- access control. Two ways that goes wrong, and this file reports both:
--
--   red    · anon / PUBLIC hold EXECUTE.
--            Postgres grants EXECUTE to PUBLIC by default, so this is what a
--            migration that writes `grant execute ... to service_role` and
--            forgets `revoke execute ... from public` produces: a privileged
--            endpoint at /rest/v1/rpc/<name> reachable with no login. That is
--            how upsert_self_machine ended up open (fixed in
--            20260820073931_revoke_public_execute_upsert_self_machine.sql).
--
--   yellow · `authenticated` holds EXECUTE and nothing on the call path ever
--            reads auth.uid().
--            Revoking PUBLIC only changes the ticket price from "free" to
--            "register an account". If the body then takes an id and never asks
--            whether the caller owns it, any logged-in user can aim it at
--            anyone else. 20260524180643_bind_definer_helpers_to_auth_uid.sql
--            bound eleven helpers to auth.uid() by hand and missed the ones
--            whose parameters were not named p_user_id — same family of bug,
--            missed at hardening time rather than grown afterwards.
--            Yellow, not red, because a function can be safe without naming
--            auth.uid() itself (see the transitive resolution below), and
--            because deciding what to do about one is a judgement call.
--
-- Scope: the schemas PostgREST exposes, i.e. `[api] schemas` in
-- supabase/config.toml. Supabase-managed schemas (auth, storage, extensions,
-- graphql, realtime) are deliberately out — we do not own their grants, and
-- including them would bury our own regressions in vendor noise.

with recursive fn as (
  select p.oid,
         n.nspname                                 as schema,
         p.proname                                 as function,
         pg_get_function_identity_arguments(p.oid) as args,
         p.prosrc,
         p.prosecdef,
         has_function_privilege('anon',          p.oid, 'EXECUTE') as anon_execute,
         has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_execute,
         case
           when p.proacl is null then true  -- NULL acl == built-in default == EXECUTE TO PUBLIC
           else exists (
             select 1 from aclexplode(p.proacl) a
              where a.grantee = 0 and a.privilege_type = 'EXECUTE'
           )
         end                                       as public_execute,
         coalesce(p.proacl::text, '(default: EXECUTE TO PUBLIC)') as acl
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'graphql_public', 'pendingbot')
     and p.prokind = 'f'
),

-- Call graph, by looking for a callee's name inside a caller's body. A
-- heuristic — a name inside a comment or a string literal counts as a call —
-- but a cheap and load-bearing one: without it the yellow rule flags every
-- function that delegates its caller check to a shared guard
-- (`_assert_group_role`, `_grp_require_caller`, `subject_has_user_access`, …),
-- which on this database is 12 of 16 hits, i.e. 75% noise. The heuristic errs
-- toward silence, so pair it with the fact that red is checked independently.
edge as (
  select caller.oid as caller_oid, callee.oid as callee_oid
    from fn caller
    join fn callee
      on caller.oid <> callee.oid
     and caller.prosrc ~ ('\m' || callee.function || '\M')
),

-- Functions that end up reading auth.uid(), directly or through anything they
-- call. Verified 2026-08-21 against a hand audit of all 72 authenticated-
-- executable SECURITY DEFINER functions on production: this closure reproduces
-- that audit's tier-3 list exactly — same four, no more, no fewer.
binds_caller as (
  select oid from fn where prosrc ~* 'auth\.uid\s*\('
  union
  select e.caller_oid from edge e join binds_caller b on b.oid = e.callee_oid
)

select 'public_or_anon_execute' as finding,
       'red'                    as severity,
       f.schema, f.function, f.args,
       f.anon_execute, f.authenticated_execute, f.public_execute, f.acl
  from fn f
 where f.prosecdef
   and (f.anon_execute or f.public_execute)

union all

select 'authenticated_no_caller_binding' as finding,
       'yellow'                          as severity,
       f.schema, f.function, f.args,
       f.anon_execute, f.authenticated_execute, f.public_execute, f.acl
  from fn f
 where f.prosecdef
   and f.authenticated_execute
   and not (f.anon_execute or f.public_execute)   -- already reported as red
   and f.oid not in (select oid from binds_caller)

order by 2, 3, 4, 5;
