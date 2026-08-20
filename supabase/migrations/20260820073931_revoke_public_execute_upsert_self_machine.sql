-- Close an unauthenticated write hole on pendingbot.upsert_self_machine.
--
-- `20260614123749_machine_table.sql` created this SECURITY DEFINER function and
-- only wrote `grant execute ... to service_role`. It never wrote the matching
-- `revoke execute ... from public`, so the function kept Postgres' built-in
-- default (EXECUTE TO PUBLIC). Because `pendingbot` is a PostgREST-exposed
-- schema and the publishable key is public by design, that made
-- `POST /rest/v1/rpc/upsert_self_machine` a write endpoint reachable with no
-- login at all — and SECURITY DEFINER bypasses the `machine_self_*` RLS
-- policies, so an anonymous caller could forge machine rows for any subject,
-- overwrite other people's machine names, flip them to `online`, or flood the
-- table. (Reproduced end-to-end on a local `supabase db reset`: anon RPC
-- returned HTTP 200 and inserted a row against another user's subject.)
--
-- Two fixes, matching what `20260524175632_harden_function_execute_privileges.sql`
-- and `20260524180643_bind_definer_helpers_to_auth_uid.sql` already established:
--   1) take the privilege away (the actual fix);
--   2) self-authorize inside the body, so a future re-grant is not instantly
--      exploitable again (defense in depth).
--
-- A CI gate (`bun run db:definer-gate`) now fails on any SECURITY DEFINER
-- function in an exposed schema that anon/PUBLIC can execute, so this class of
-- regression stops being a matter of remembering.

BEGIN;

-- 1) Self-authorization inside the body.
--
-- Service-role callers keep working unchanged: `auth.uid()` is NULL for the
-- service role, and Edge (`apps/edge/src/routes/machines.ts`) already resolves
-- the caller's own subject before invoking this. Any JWT-bearing caller may
-- only touch a subject they own — the same rule the `machine_self_*` RLS
-- policies enforce, restated here because SECURITY DEFINER bypasses RLS.
CREATE OR REPLACE FUNCTION pendingbot.upsert_self_machine(
  p_subject_id uuid,
  p_device_id text,
  p_display_name text
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public, auth
AS $$
declare v_id uuid;
begin
  if auth.uid() is not null and not exists (
    select 1
      from pendingbot.subjects s
     where s.id = p_subject_id
       and s.kind = 'user_account'
       and s.user_id = auth.uid()
  ) then
    raise exception 'upsert_self_machine: subject % is not owned by the caller', p_subject_id
      using errcode = '42501';
  end if;

  insert into pendingbot.machine (subject_id, kind, device_id, display_name, last_seen_at, status, updated_at)
  values (p_subject_id, 'computer', p_device_id, p_display_name, now(), 'online', now())
  on conflict (subject_id, device_id) where device_id is not null
  do update set display_name = excluded.display_name, last_seen_at = now(), status = 'online', updated_at = now()
  returning id into v_id;
  return v_id;
end; $$;

-- 2) Take the privilege away. `CREATE OR REPLACE` preserves the existing ACL,
-- so the revoke has to be explicit and has to come after the replace.
REVOKE EXECUTE ON FUNCTION pendingbot.upsert_self_machine(uuid, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.upsert_self_machine(uuid, text, text)
  TO service_role;

-- Sweep the rest of the schema the same way the 2026-05 hardening did, so any
-- other function that inherited the PUBLIC default since then is caught too.
-- Audited before writing this (live + fresh local replay): besides the function
-- above, only four non-SECURITY-DEFINER helpers still carried the PUBLIC grant
-- — `bot_friend_inquiries_touch_updated`, `prevent_crew_parent_cycle`,
-- `tg_short_links_touch_updated_at` (trigger functions, not RPC-callable) and
-- `normalize_email` (pure helper, not referenced by any DEFAULT, CHECK or index
-- expression, so no runtime caller loses anything). Nothing depends on PUBLIC
-- for `authenticated` access — every intentional authenticated RPC holds its
-- own explicit grant.
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA pendingbot FROM anon, PUBLIC;

COMMIT;
