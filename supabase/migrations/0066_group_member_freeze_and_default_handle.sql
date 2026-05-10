-- Group overhaul — freeze gate + auto-minted default 'number' handle.
--
-- Two pieces, kept in one migration because they're both tied to the
-- "create a group / a member crosses their cap" lifecycle and the
-- iOS group-overhaul branch needs both at once.
--
-- 1. group_member_billing.frozen_at + a BEFORE-UPDATE trigger that flips
--    the timestamp whenever overdrawn flips. iOS uses frozen_at to hide
--    new messages + disable the composer for the affected member from
--    the moment they crossed the cap (or ran out of balance) — older
--    messages stay visible because the column is per-flip, not absolute.
--
-- 2. apply_audit_split — also flip overdrawn=true when a split row gets
--    skipped because the member's *balance* couldn't cover their
--    allocation (skipped_overdrawn) OR their per-group cap couldn't
--    (skipped_capped). Today only the cap path flips overdrawn, via the
--    spent_credits >= cap_credits guard inside apply_audit_split itself
--    — a member with empty balance kept a clean overdrawn=false, so
--    iOS had no way to tell them apart from a normal sender. The user-
--    facing rule is "running out of balance freezes you the same way
--    hitting the cap does", which this fixes.
--
-- 3. _mint_default_group_handles trigger on conversation_group_meta —
--    every fresh group gets a random 8-char 'number' AND 'qr' handle
--    right away, same way users get a registration-time 'id' handle.
--    This way a group has an ID to show in settings + a scannable QR
--    the moment it's created, no explicit admin step needed; admin can
--    still rotate either through the existing group_set_handle RPC.

BEGIN;

-- ─────────────────────────────────────────────────────────────────────
-- 1. group_member_billing.frozen_at + freeze trigger
-- ─────────────────────────────────────────────────────────────────────

ALTER TABLE pendingbot.group_member_billing
  ADD COLUMN IF NOT EXISTS frozen_at timestamp with time zone;

COMMENT ON COLUMN pendingbot.group_member_billing.frozen_at IS
  'Wall-clock time at which this member crossed their cap or ran out of '
  'balance. Set by trigger when overdrawn flips false→true; cleared when '
  'overdrawn flips back. iOS uses it to scope "messages from this point '
  'forward are hidden" without needing to remember the flip server-side.';

CREATE OR REPLACE FUNCTION pendingbot._group_member_billing_freeze_trigger()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.overdrawn AND NOT COALESCE(OLD.overdrawn, false) THEN
    NEW.frozen_at := now();
  ELSIF NOT NEW.overdrawn AND COALESCE(OLD.overdrawn, false) THEN
    NEW.frozen_at := NULL;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS group_member_billing_freeze_trg
  ON pendingbot.group_member_billing;

CREATE TRIGGER group_member_billing_freeze_trg
  BEFORE UPDATE OF overdrawn ON pendingbot.group_member_billing
  FOR EACH ROW
  EXECUTE FUNCTION pendingbot._group_member_billing_freeze_trigger();

-- Backfill: any row that was already overdrawn before this migration
-- gets a synthetic frozen_at = now() so iOS doesn't suddenly hide every
-- message in the group's history.
UPDATE pendingbot.group_member_billing
   SET frozen_at = now()
 WHERE overdrawn = true
   AND frozen_at IS NULL;

-- ─────────────────────────────────────────────────────────────────────
-- 2. apply_audit_split — also flip overdrawn on skipped_* statuses
-- ─────────────────────────────────────────────────────────────────────
--
-- Same body as 0045, with one extra branch after the debited update:
-- when the row was skipped (cap or balance), flip overdrawn=true so
-- subsequent split scans exclude this member and the freeze trigger
-- stamps frozen_at. Repeating CREATE OR REPLACE FUNCTION for the whole
-- function keeps the source authoritative in this file.

CREATE OR REPLACE FUNCTION pendingbot.apply_audit_split(
  p_audit_log_id uuid,
  p_splits jsonb
) RETURNS void
LANGUAGE plpgsql
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
declare
  conv_id uuid;
  s jsonb;
  user_uuid uuid;
  share int;
  debited bigint;
  status_text text;
begin
  select audit_log.conversation_id into conv_id
    from pendingbot.audit_log
   where audit_log.id = p_audit_log_id;
  if conv_id is null then
    raise exception 'audit_log row % not found', p_audit_log_id;
  end if;

  for s in select * from jsonb_array_elements(p_splits) loop
    user_uuid    := (s->>'user_id')::uuid;
    share        := coalesce((s->>'share_bps')::int, 0);
    debited      := coalesce((s->>'debited_credits')::bigint, 0);
    status_text  := coalesce(s->>'debit_status', 'debited');

    insert into pendingbot.audit_log_splits
      (audit_log_id, user_id, share_bps, debited_credits, debit_status)
    values
      (p_audit_log_id, user_uuid, share, debited, status_text)
    on conflict (audit_log_id, user_id) do update
      set share_bps       = excluded.share_bps,
          debited_credits = excluded.debited_credits,
          debit_status    = excluded.debit_status;

    if status_text = 'debited' and debited > 0 then
      perform pendingbot.billing_debit(user_uuid, p_audit_log_id, debited);
      update pendingbot.group_member_billing
         set spent_credits = spent_credits + debited,
             overdrawn = case
               when cap_credits is not null and (spent_credits + debited) >= cap_credits
                 then true
               else overdrawn
             end
       where conversation_id = conv_id and user_id = user_uuid;
    elsif status_text in ('skipped_overdrawn', 'skipped_capped') then
      -- Caller decided this member couldn't pay: cap exhausted or
      -- balance below allocation. Either way, freeze them out of the
      -- group until the condition clears (cap raised, balance topped up).
      update pendingbot.group_member_billing
         set overdrawn = true
       where conversation_id = conv_id
         and user_id = user_uuid
         and overdrawn = false;
    end if;
  end loop;
end $$;
ALTER FUNCTION pendingbot.apply_audit_split(uuid, jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.apply_audit_split(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.apply_audit_split(uuid, jsonb) TO service_role;

-- ─────────────────────────────────────────────────────────────────────
-- 3. Auto-mint default 'number' + 'qr' handles on group creation
-- ─────────────────────────────────────────────────────────────────────
--
-- conversation_group_meta is the 1:1 sidecar that open_group_conv
-- inserts into right after creating the conversations row. Hook a
-- trigger here rather than editing open_group_conv so we keep the RPC
-- body untouched.
--
-- Alphabet skips visually ambiguous chars (0/o/1/l/i) and is lowercase
-- to match the existing iOS handle-mint helper. Length 8 + 32-char
-- alphabet → ~40 bits of entropy; collisions on a unique constraint
-- are effectively impossible at our scale, but we retry up to 5×
-- defensively.

CREATE OR REPLACE FUNCTION pendingbot._mint_random_group_handle(
  p_conv_id uuid,
  p_handle_type text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pendingbot', 'public'
AS $$
DECLARE
  v_alphabet text := 'abcdefghijkmnpqrstuvwxyz23456789';
  v_token text;
  v_attempt int := 0;
BEGIN
  LOOP
    v_token := '';
    FOR i IN 1..8 LOOP
      v_token := v_token || substr(
        v_alphabet,
        1 + floor(random() * length(v_alphabet))::int,
        1
      );
    END LOOP;
    BEGIN
      INSERT INTO pendingbot.group_join_handles
        (conversation_id, handle_type, value, enabled)
      VALUES
        (p_conv_id, p_handle_type, v_token, true);
      RETURN;
    EXCEPTION WHEN unique_violation THEN
      v_attempt := v_attempt + 1;
      IF v_attempt > 5 THEN RAISE; END IF;
    END;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION pendingbot._mint_default_group_handles()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pendingbot', 'public'
AS $$
BEGIN
  -- Idempotent: skip whichever handle type the group already has, so
  -- re-runs and partial backfills don't double-insert.
  IF NOT EXISTS (
    SELECT 1 FROM pendingbot.group_join_handles
     WHERE conversation_id = NEW.conversation_id
       AND handle_type = 'number'
  ) THEN
    PERFORM pendingbot._mint_random_group_handle(NEW.conversation_id, 'number');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pendingbot.group_join_handles
     WHERE conversation_id = NEW.conversation_id
       AND handle_type = 'qr'
  ) THEN
    PERFORM pendingbot._mint_random_group_handle(NEW.conversation_id, 'qr');
  END IF;

  RETURN NEW;
END $$;
ALTER FUNCTION pendingbot._mint_default_group_handles() OWNER TO postgres;

DROP TRIGGER IF EXISTS conversation_group_meta_default_handle_trg
  ON pendingbot.conversation_group_meta;

CREATE TRIGGER conversation_group_meta_default_handle_trg
  AFTER INSERT ON pendingbot.conversation_group_meta
  FOR EACH ROW
  EXECUTE FUNCTION pendingbot._mint_default_group_handles();

-- Backfill: any group that was created before this trigger and doesn't
-- have either a 'number' or 'qr' handle yet gets one minted now.
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT m.conversation_id
      FROM pendingbot.conversation_group_meta m
      LEFT JOIN pendingbot.group_join_handles h
        ON h.conversation_id = m.conversation_id
       AND h.handle_type = 'number'
     WHERE h.conversation_id IS NULL
  LOOP
    PERFORM pendingbot._mint_random_group_handle(r.conversation_id, 'number');
  END LOOP;

  FOR r IN
    SELECT m.conversation_id
      FROM pendingbot.conversation_group_meta m
      LEFT JOIN pendingbot.group_join_handles h
        ON h.conversation_id = m.conversation_id
       AND h.handle_type = 'qr'
     WHERE h.conversation_id IS NULL
  LOOP
    PERFORM pendingbot._mint_random_group_handle(r.conversation_id, 'qr');
  END LOOP;
END $$;

-- ─────────────────────────────────────────────────────────────────────
-- 4. Participant-visible status policy on group_member_billing
-- ─────────────────────────────────────────────────────────────────────
--
-- Members need to see *each other's* frozen state in the settings UI
-- ("X 已达上限"). The two existing SELECT policies on group_member_
-- billing only let you read your own row + admins read everyone's, so
-- a regular member can't tell whether a peer is frozen.
--
-- Adding a third permissive SELECT policy that lets any participant
-- read every row in their group. This deliberately also exposes
-- spent_credits / cap_credits to peers — the per-member spend has
-- always been derivable from audit_log_splits anyway (which lives
-- under a similar admin/self gate but trivially leaks via the
-- per-message billing UI). If we later want to hide those columns
-- from non-admin peers, swap this for a column-filtered VIEW.

CREATE POLICY group_member_billing_participant_status_read
  ON pendingbot.group_member_billing FOR SELECT
  USING (pendingbot.is_participant(conversation_id));

COMMIT;
