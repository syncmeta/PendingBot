-- Harden exposed function privileges.
--
-- Supabase/Postgres grants EXECUTE on functions to PUBLIC by default, and
-- exposed schemas make callable functions reachable through /rest/v1/rpc/*.
-- SECURITY DEFINER functions must therefore be explicitly private unless they
-- are intentional authenticated RPC endpoints.

BEGIN;

-- Restore the public-schema RLS safety-net (event trigger `ensure_rls` running
-- `public.rls_auto_enable`). It predates the 0001_init squash and lived only in
-- the live database, never in the migration ledger — so a fresh rebuild (the EU
-- region move, 2026-06) lacked it and the REVOKE near the end of this file
-- errored with 42883 (function does not exist). Recreate it here so the ledger
-- is self-contained and any empty DB can replay cleanly. (Verbatim copy of the
-- live definition.)
CREATE OR REPLACE FUNCTION public.rls_auto_enable()
 RETURNS event_trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$function$;

-- The event trigger needs elevated privileges. If the migration role can't
-- create it, warn instead of aborting — the function still gets the hardened
-- grant below, and the trigger only auto-enforces public-schema tables, which
-- this project never uses for application data (all app tables live in
-- `pendingbot`).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_event_trigger WHERE evtname = 'ensure_rls') THEN
    BEGIN
      CREATE EVENT TRIGGER ensure_rls ON ddl_command_end
        EXECUTE FUNCTION public.rls_auto_enable();
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'ensure_rls event trigger not created: %', SQLERRM;
    END;
  END IF;
END
$$;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA pendingbot
  REVOKE EXECUTE ON FUNCTIONS FROM anon, authenticated, public;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM anon, authenticated, public;

-- Kill inherited anonymous access first. Authenticated RPC access is re-granted
-- below only for client-facing functions that intentionally self-authorize.
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA pendingbot FROM anon, public;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM anon, public;

-- Service/admin/internal billing functions. Board and Edge call these with the
-- service role; end users must not be able to invoke them directly.
REVOKE EXECUTE ON FUNCTION pendingbot.billing_admin_grant(uuid, bigint, text)
  FROM authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.billing_admin_grant(uuid, bigint, text)
  TO service_role;

REVOKE EXECUTE ON FUNCTION pendingbot.billing_issue_codes(integer, bigint, text)
  FROM authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.billing_issue_codes(integer, bigint, text)
  TO service_role;

REVOKE EXECUTE ON FUNCTION pendingbot.billing_credit(
  uuid, bigint, text, uuid, uuid, uuid, text, jsonb
) FROM authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.billing_credit(
  uuid, bigint, text, uuid, uuid, uuid, text, jsonb
) TO service_role;

REVOKE EXECUTE ON FUNCTION pendingbot.billing_debit(uuid, uuid, bigint)
  FROM authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.billing_debit(uuid, uuid, bigint)
  TO service_role;

REVOKE EXECUTE ON FUNCTION pendingbot.billing_signup_bonus(uuid)
  FROM authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.billing_signup_bonus(uuid)
  TO service_role;

REVOKE EXECUTE ON FUNCTION pendingbot.billing_signup_bonus_trigger()
  FROM authenticated;

REVOKE EXECUTE ON FUNCTION pendingbot.billing_config_int(text)
  FROM authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.billing_config_int(text)
  TO service_role;

-- Signup/bootstrap/seed helpers are trigger- or service-only. Keep the public
-- product RPCs (open_self_conv/open_user_bot_conv/start_user_bot_turn) separate.
REVOKE EXECUTE ON FUNCTION pendingbot.bootstrap_new_user_trigger()
  FROM authenticated;
REVOKE EXECUTE ON FUNCTION pendingbot.bootstrap_user_id(uuid, text, jsonb)
  FROM authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.bootstrap_user_id(uuid, text, jsonb)
  TO service_role;

REVOKE EXECUTE ON FUNCTION pendingbot.ensure_self_conv(uuid)
  FROM authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.ensure_self_conv(uuid)
  TO service_role;

REVOKE EXECUTE ON FUNCTION pendingbot.seed_example_letter(uuid)
  FROM authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.seed_example_letter(uuid)
  TO service_role;

REVOKE EXECUTE ON FUNCTION pendingbot.seed_sample_dialogue(uuid, uuid, uuid, text)
  FROM authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.seed_sample_dialogue(uuid, uuid, uuid, text)
  TO service_role;

-- Trigger/internal helpers that should never be public RPC endpoints.
REVOKE EXECUTE ON FUNCTION pendingbot._before_auth_user_delete()
  FROM authenticated;
REVOKE EXECUTE ON FUNCTION pendingbot._mint_default_group_handles()
  FROM authenticated;
REVOKE EXECUTE ON FUNCTION pendingbot._mint_random_group_handle(uuid, text)
  FROM authenticated;
REVOKE EXECUTE ON FUNCTION pendingbot._group_member_billing_freeze_trigger()
  FROM authenticated;
REVOKE EXECUTE ON FUNCTION pendingbot.notify_realtime()
  FROM authenticated;
REVOKE EXECUTE ON FUNCTION pendingbot.reject_disposable_email()
  FROM authenticated;
REVOKE EXECUTE ON FUNCTION pendingbot.tg_user_bot_conv_to_contact()
  FROM authenticated;
REVOKE EXECUTE ON FUNCTION pendingbot.tg_users_is_admin_audit()
  FROM authenticated;
REVOKE EXECUTE ON FUNCTION pendingbot.update_unread_counts()
  FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.rls_auto_enable()
  FROM authenticated, anon, public;

-- Explicitly preserve intentional authenticated RPC surface after PUBLIC revoke.
GRANT EXECUTE ON FUNCTION pendingbot.billing_redeem(text) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.bot_invites_add(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.list_bot_invitees(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.open_self_conv() TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.open_user_bot_conv(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.start_user_bot_turn(uuid, uuid, text, uuid[]) TO authenticated;

COMMIT;
