-- Security / RLS hardening — four independent fixes, grouped because
-- they share shape (defensive RLS + audit + index) and none touch
-- product behaviour:
--
--   1. billing_config — was readable by every authenticated user via
--      `USING (true)`. Tighten to a key allowlist so future admin knobs
--      (promo codes, segment-specific thresholds, etc) are private by
--      default. Current code only reads min_balance_threshold and
--      signup_bonus_credits, both deliberately public.
--
--   2. attachments — had INSERT + SELECT policies but no UPDATE/DELETE.
--      RLS with no policy denies, so today users simply can't touch
--      their own rows (no observed breakage because writes go through
--      the worker w/ service role). Adding explicit self-only policies
--      gives a future user-client write path the correct gate and
--      makes the table's intent legible.
--
--   3. attachments — `user_id` FK had no covering index. Listing a
--      user's uploads scans on conversation_id only; user-scoped
--      cascade-on-delete would also seq-scan. Add the index.
--
--   4. users.is_admin — no trail of who promoted whom. Add a trigger
--      that writes to admin_audit on INSERT (admin=true) and on UPDATE
--      whenever is_admin changes. `actor_id` is auth.uid() (the admin
--      doing the promotion) or NULL if the change came from service
--      role / migration.

BEGIN;

-- ============================================================
-- 1. billing_config — replace full-table SELECT with key allowlist
-- ============================================================

DROP POLICY IF EXISTS billing_config_read ON pendingbot.billing_config;

-- Future-proof default-deny: only keys explicitly listed here are
-- readable by authenticated users. Adding a new public key means a
-- migration; private keys (markup overrides, segment rules, ops
-- thresholds…) stay invisible.
CREATE POLICY billing_config_read ON pendingbot.billing_config
  FOR SELECT TO authenticated
  USING (key IN ('min_balance_threshold', 'signup_bonus_credits'));

-- ============================================================
-- 2. attachments — explicit self-only UPDATE / DELETE
-- ============================================================

DROP POLICY IF EXISTS attachments_self_update ON pendingbot.attachments;
CREATE POLICY attachments_self_update ON pendingbot.attachments
  FOR UPDATE TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS attachments_self_delete ON pendingbot.attachments;
CREATE POLICY attachments_self_delete ON pendingbot.attachments
  FOR DELETE TO authenticated
  USING (user_id = auth.uid());

-- ============================================================
-- 3. attachments — index user_id (FK had none)
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_attachments_user
  ON pendingbot.attachments USING btree (user_id);

-- ============================================================
-- 4. users.is_admin — audit trigger
-- ============================================================

CREATE OR REPLACE FUNCTION pendingbot.tg_users_is_admin_audit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = pendingbot, public
AS $$
DECLARE
  v_actor uuid;
BEGIN
  -- auth.uid() returns the JWT subject when the change came from a
  -- user-scoped client. NULL means service_role / migration / cron.
  v_actor := auth.uid();

  IF TG_OP = 'INSERT' AND NEW.is_admin THEN
    INSERT INTO pendingbot.admin_audit
      (actor_id, action, target_kind, target_id, before, after)
    VALUES
      (v_actor, 'user.set_admin', 'user', NEW.id::text,
       NULL,
       jsonb_build_object('is_admin', true));
  ELSIF TG_OP = 'UPDATE' AND COALESCE(NEW.is_admin, false) IS DISTINCT FROM COALESCE(OLD.is_admin, false) THEN
    INSERT INTO pendingbot.admin_audit
      (actor_id, action, target_kind, target_id, before, after)
    VALUES
      (v_actor,
       CASE WHEN NEW.is_admin THEN 'user.set_admin' ELSE 'user.unset_admin' END,
       'user', NEW.id::text,
       jsonb_build_object('is_admin', OLD.is_admin),
       jsonb_build_object('is_admin', NEW.is_admin));
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS users_is_admin_audit ON pendingbot.users;
CREATE TRIGGER users_is_admin_audit
  AFTER INSERT OR UPDATE OF is_admin ON pendingbot.users
  FOR EACH ROW
  EXECUTE FUNCTION pendingbot.tg_users_is_admin_audit();

COMMIT;
