-- Drop the `public_open` visibility tier.
--
-- Product call: bots are now strictly `private` (creator-only) or
-- `public_invite` (creator + invitees). The "anyone authed can add"
-- branch is going away because (a) it leaks user-created bots into
-- everyone's friend tab and (b) the new bot-social-graph design lets
-- a bot reach beyond its owner via `ask_friend`, which assumes a
-- vetted human friend set — `public_open` was the wrong primitive.
--
-- Per product direction: existing `public_open` bots are deleted
-- outright, no migration to `public_invite`. Cascades handle most
-- dependents; we manually clear the few that don't (review_runs, and
-- orphan conversation_participants rows, since `participant_id` has
-- no FK).

BEGIN;

-- 1. Clean up dependents that won't cascade on their own.
--    (review_runs / bot_reflections / discuss_settings / surf_runs were
--    referenced in earlier `bots` FK lists but have since been dropped
--    by 0021/0047 — only conversation_participants still needs manual
--    cleanup because its `participant_id` carries no FK at all.)
DELETE FROM pendingbot.conversation_participants
 WHERE participant_type = 'bot'
   AND participant_id IN (SELECT id FROM pendingbot.bots WHERE visibility = 'public_open');

-- 2. Delete the bots themselves. CASCADE FKs that still exist:
--    user_bot_contacts, bot_invites, bot_lookbacks,
--    group_bot_descriptions, realtime_sessions, skills,
--    bot_code_exec_requests, scroll_runs, bot_user_lookback_counter,
--    temporary_groups_crew. SET NULL FKs preserve rows: conversations
--    .bot_id, messages.sender_bot_id, subagent_conversations
--    .spawner_bot_id, crew_targeted_announcements.master_bot_id,
--    crew_dag.captain_bot_id, crew_dag_nodes.created_by_bot_id.
DELETE FROM pendingbot.bots WHERE visibility = 'public_open';

-- 3. Tighten the CHECK constraint to the two remaining tiers.
ALTER TABLE pendingbot.bots
  DROP CONSTRAINT IF EXISTS bots_visibility_check;

ALTER TABLE pendingbot.bots
  ADD CONSTRAINT bots_visibility_check
  CHECK (visibility IN ('private', 'public_invite'));

-- 4. New bots default to private (was public_open). UI funnels users to
--    public_invite explicitly when they want to publish.
ALTER TABLE pendingbot.bots
  ALTER COLUMN visibility SET DEFAULT 'private';

COMMENT ON COLUMN pendingbot.bots.visibility IS
  'private | public_invite. Private→public_invite is one-way (enforced by bots_guard_public_update trigger).';

-- 5. Redo bots_visible_read RLS without the public_open branch.
DROP POLICY IF EXISTS bots_visible_read ON pendingbot.bots;

CREATE POLICY bots_visible_read ON pendingbot.bots FOR SELECT
  USING (
    creator_id = auth.uid()
    OR creator_id IS NULL  -- preset bots stay visible to everyone
    OR (visibility = 'public_invite'
        AND pendingbot.is_bot_invitee(id, auth.uid()))
  );

-- 6. Redo user_bot_contacts_self_insert similarly.
DROP POLICY IF EXISTS user_bot_contacts_self_insert ON pendingbot.user_bot_contacts;

CREATE POLICY user_bot_contacts_self_insert
  ON pendingbot.user_bot_contacts FOR INSERT
  WITH CHECK (
    user_id = auth.uid()
    AND EXISTS (
      SELECT 1 FROM pendingbot.bots b
      WHERE b.id = user_bot_contacts.bot_id
        AND b.is_active = true
        AND (
          b.creator_id = auth.uid()
          OR b.creator_id IS NULL
          OR (
            b.visibility = 'public_invite'
            AND EXISTS (
              SELECT 1 FROM pendingbot.bot_invites bi
              WHERE bi.bot_id = b.id AND bi.user_id = auth.uid()
            )
          )
        )
    )
  );

-- 7. open_user_bot_conv: drop the public_open branch (private + public_invite remain).
CREATE OR REPLACE FUNCTION pendingbot.open_user_bot_conv(p_bot_id uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pendingbot', 'public'
    AS $$
declare
  caller_id uuid := auth.uid();
  conv_id   uuid;
  bot_row   record;
begin
  if caller_id is null then
    raise exception 'auth required';
  end if;

  select id, visibility, creator_id, is_active into bot_row
    from pendingbot.bots where id = p_bot_id;

  if bot_row is null or bot_row.is_active = false then
    raise exception 'bot not found or inactive';
  end if;

  if bot_row.visibility = 'private'
     and bot_row.creator_id is distinct from caller_id then
    raise exception '没有权限打开此机器人';
  end if;

  if bot_row.visibility = 'public_invite'
     and bot_row.creator_id is distinct from caller_id
     and bot_row.creator_id is not null
     and not exists (
       select 1 from pendingbot.bot_invites
        where bot_id = p_bot_id and user_id = caller_id
     ) then
    raise exception '没有权限打开此机器人';
  end if;

  insert into pendingbot.conversations
    (conversation_type, feature, user_id, bot_id, title)
  values
    ('user_bot', 'message', caller_id, p_bot_id,
     coalesce(pendingbot.random_place_name(), '新对话'))
  returning id into conv_id;

  insert into pendingbot.conversation_participants
    (conversation_id, participant_type, participant_id, role)
  values
    (conv_id, 'user', caller_id, 'owner'),
    (conv_id, 'bot',  p_bot_id,  'member');

  return conv_id;
end $$;

COMMIT;
