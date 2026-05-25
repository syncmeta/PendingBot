-- Harden exposed function privileges.
--
-- Supabase/Postgres grants EXECUTE on functions to PUBLIC by default, and
-- exposed schemas make callable functions reachable through /rest/v1/rpc/*.
-- SECURITY DEFINER functions must therefore be explicitly private unless they
-- are intentional authenticated RPC endpoints.

BEGIN;

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
