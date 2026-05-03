-- Bots become visibility-aware: private (creator-only) vs public.
-- Public bots split into two access levels:
--   public_invite — creator + invitees only
--   public_open   — anyone with auth
--
-- Once a bot is public, the creator can ONLY toggle public_invite ↔
-- public_open. They cannot rename, change model, deactivate, or revert
-- to private (the bot is now an IM-style account others may have added).
-- Private bots keep full creator control and can be deleted; promoting
-- private → public is one-way.

BEGIN;

-- ── bots: creator_id + visibility ────────────────────────────────────
-- Preset bots stay creator_id IS NULL (system-owned). User-created bots
-- carry the auth uid. ON DELETE SET NULL: deleting the creator orphans
-- public bots cleanly (they continue as bot-IM-accounts) and leaves
-- private bots zombie-unreachable until _delete_account_internal nukes
-- them (see below).
ALTER TABLE pendingbot.bots
  ADD COLUMN creator_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN visibility text NOT NULL DEFAULT 'public_open'
    CHECK (visibility IN ('private', 'public_invite', 'public_open'));

COMMENT ON COLUMN pendingbot.bots.creator_id IS
  'NULL for system preset bots. Otherwise the user who created the bot. Private: full owner control. Public: limited to visibility toggling.';
COMMENT ON COLUMN pendingbot.bots.visibility IS
  'private | public_invite | public_open. Private→public is one-way. Public bots cannot revert to private.';

CREATE INDEX idx_bots_creator ON pendingbot.bots (creator_id) WHERE creator_id IS NOT NULL;
CREATE INDEX idx_bots_visibility ON pendingbot.bots (visibility);

-- ── bot_invites: gate for public_invite bots ─────────────────────────
CREATE TABLE pendingbot.bot_invites (
  bot_id     uuid NOT NULL REFERENCES pendingbot.bots(id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  invited_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (bot_id, user_id)
);
ALTER TABLE pendingbot.bot_invites OWNER TO postgres;
ALTER TABLE pendingbot.bot_invites ENABLE ROW LEVEL SECURITY;

CREATE INDEX idx_bot_invites_user ON pendingbot.bot_invites (user_id);

-- ── FKs: keep chat history when a private bot is deleted ─────────────
-- conversations.bot_id and messages.sender_bot_id were RESTRICT-ish
-- (default). Switch to SET NULL so the user's history survives the
-- delete (the bot reference becomes null; iOS already falls back to
-- conv.title / "—"). review_runs stays CASCADE — those are per-bot
-- reflections, no point keeping orphans.
ALTER TABLE pendingbot.conversations
  DROP CONSTRAINT conversations_bot_id_fkey,
  ADD  CONSTRAINT conversations_bot_id_fkey
    FOREIGN KEY (bot_id) REFERENCES pendingbot.bots(id) ON DELETE SET NULL;
ALTER TABLE pendingbot.messages
  DROP CONSTRAINT messages_sender_bot_id_fkey,
  ADD  CONSTRAINT messages_sender_bot_id_fkey
    FOREIGN KEY (sender_bot_id) REFERENCES pendingbot.bots(id) ON DELETE SET NULL;

-- ── RLS: bots ────────────────────────────────────────────────────────
DROP POLICY IF EXISTS bots_authenticated_read ON pendingbot.bots;

CREATE POLICY bots_visible_read ON pendingbot.bots FOR SELECT
  USING (
    visibility = 'public_open'
    OR creator_id = auth.uid()
    OR (visibility = 'public_invite' AND EXISTS (
      SELECT 1 FROM pendingbot.bot_invites bi
      WHERE bi.bot_id = bots.id AND bi.user_id = auth.uid()
    ))
  );

CREATE POLICY bots_creator_insert ON pendingbot.bots FOR INSERT
  WITH CHECK (creator_id = auth.uid());

CREATE POLICY bots_creator_update ON pendingbot.bots FOR UPDATE
  USING (creator_id = auth.uid())
  WITH CHECK (creator_id = auth.uid());

-- Public bots are not user-deletable; only private rows can be removed
-- by their creator. Preset bots (creator_id IS NULL) are unreachable
-- from this policy entirely.
CREATE POLICY bots_creator_delete ON pendingbot.bots FOR DELETE
  USING (creator_id = auth.uid() AND visibility = 'private');

-- ── RLS: bot_invites ─────────────────────────────────────────────────
CREATE POLICY bot_invites_creator_all ON pendingbot.bot_invites
  USING (EXISTS (
    SELECT 1 FROM pendingbot.bots b
    WHERE b.id = bot_invites.bot_id AND b.creator_id = auth.uid()
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM pendingbot.bots b
    WHERE b.id = bot_invites.bot_id AND b.creator_id = auth.uid()
  ));

CREATE POLICY bot_invites_self_read ON pendingbot.bot_invites FOR SELECT
  USING (user_id = auth.uid());

-- ── Trigger: lock public bot columns once published ──────────────────
-- Fires on every UPDATE; preset bots (creator_id IS NULL) are ignored
-- so admins can still tweak the seed roster via service role + db reset.
CREATE FUNCTION pendingbot.bots_guard_public_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.creator_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF OLD.visibility = 'private' THEN
    -- private creator has full power; promotion to public is allowed
    -- (one-way; the public branch below blocks the reverse).
    RETURN NEW;
  END IF;

  IF NEW.visibility = 'private' THEN
    RAISE EXCEPTION '公有机器人不能转回私有';
  END IF;

  IF NEW.slug         IS DISTINCT FROM OLD.slug
  OR NEW.display_name IS DISTINCT FROM OLD.display_name
  OR NEW.model_id     IS DISTINCT FROM OLD.model_id
  OR NEW.output_mode  IS DISTINCT FROM OLD.output_mode
  OR NEW.is_active    IS DISTINCT FROM OLD.is_active
  OR NEW.config       IS DISTINCT FROM OLD.config
  OR NEW.creator_id   IS DISTINCT FROM OLD.creator_id THEN
    RAISE EXCEPTION '公有机器人创建后只允许修改公开程度';
  END IF;

  RETURN NEW;
END
$$;
ALTER FUNCTION pendingbot.bots_guard_public_update() OWNER TO postgres;

CREATE TRIGGER bots_guard_public_update
  BEFORE UPDATE ON pendingbot.bots
  FOR EACH ROW EXECUTE FUNCTION pendingbot.bots_guard_public_update();

-- ── Function: bootstrap_user_id ──────────────────────────────────────
-- Restrict onboarding sample-conversation fan-out to preset bots only.
-- Without this, a brand-new user would get a user_bot conv created with
-- every active user-made public_open bot (potentially thousands later).
CREATE OR REPLACE FUNCTION pendingbot.bootstrap_user_id(p_uid uuid, p_email text, p_meta jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pendingbot', 'public'
    AS $$
declare
  bot_row record;
  conv_id uuid;
begin
  insert into pendingbot.users (id, email, display_name)
  values (
    p_uid,
    p_email,
    coalesce(p_meta->>'name', p_meta->>'full_name', '你')
  )
  on conflict (id) do nothing;

  for bot_row in
    select id, slug, display_name from pendingbot.bots
     where is_active = true and creator_id is null
  loop
    if exists (
      select 1 from pendingbot.conversations
       where user_id = p_uid
         and bot_id = bot_row.id
         and conversation_type = 'user_bot'
    ) then
      continue;
    end if;

    insert into pendingbot.conversations
      (conversation_type, feature, user_id, bot_id, title)
    values
      ('user_bot', 'message', p_uid, bot_row.id,
       coalesce(pendingbot.random_place_name(), bot_row.display_name))
    returning id into conv_id;

    insert into pendingbot.conversation_participants
      (conversation_id, participant_type, participant_id, role)
    values
      (conv_id, 'user', p_uid, 'owner'),
      (conv_id, 'bot',  bot_row.id, 'member');

    perform pendingbot.seed_sample_dialogue(conv_id, p_uid, bot_row.id, bot_row.slug);
  end loop;
end $$;

-- ── Function: open_user_bot_conv ─────────────────────────────────────
-- SECURITY DEFINER bypasses RLS, so we have to enforce visibility
-- ourselves: private requires creator; public_invite requires creator
-- or invitee; public_open is anyone authed.
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

-- ── Function: _delete_account_internal ───────────────────────────────
-- Account deletion now also nukes the user's private bots up front so
-- they don't linger as zombies (creator_id SET NULL would leave them
-- unreachable but still in the table). Public bots remain — they're
-- considered self-sufficient IM accounts once published.
CREATE OR REPLACE FUNCTION pendingbot._delete_account_internal(p_uid uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pendingbot', 'public', 'auth'
    AS $$
declare
  my_conv_ids uuid[];
  my_message_ids uuid[];
begin
  if p_uid is null then
    raise exception 'p_uid is required';
  end if;

  -- Drop private bots created by this user. Cascades bot_invites,
  -- bot_lookbacks, bot_reflections, discuss_settings, skills, review_runs;
  -- conversations.bot_id and messages.sender_bot_id SET NULL so any
  -- preserved history (e.g. cross-user log entries — there shouldn't be
  -- any for private bots, but defensive) keeps its referential shape.
  delete from pendingbot.bots
   where creator_id = p_uid and visibility = 'private';

  select coalesce(array_agg(id), '{}') into my_conv_ids
    from pendingbot.conversations where user_id = p_uid;
  select coalesce(array_agg(id), '{}') into my_message_ids
    from pendingbot.messages
   where user_id = p_uid or conversation_id = any(my_conv_ids);

  update pendingbot.messages set parent_message_id = null
   where parent_message_id = any(my_message_ids);
  update pendingbot.messages set replaces_message_id = null
   where replaces_message_id = any(my_message_ids);
  update pendingbot.messages set replaced_by_message_id = null
   where replaced_by_message_id = any(my_message_ids);

  update pendingbot.audit_log set conversation_id = null
   where conversation_id = any(my_conv_ids);
  update pendingbot.audit_log set user_id = null where user_id = p_uid;

  update pendingbot.invites set created_by = null where created_by = p_uid;
  update pendingbot.invites set used_by = null where used_by = p_uid;

  update pendingbot.tools set owner_id = null where owner_id = p_uid;

  delete from pendingbot.skills where owner_id = p_uid;
  delete from pendingbot.attachments where user_id = p_uid;

  delete from pendingbot.messages where user_id = p_uid;
  delete from pendingbot.conversation_participants
   where participant_type = 'user' and participant_id = p_uid;
  delete from pendingbot.conversations where user_id = p_uid;

  delete from auth.users where id = p_uid;
end $$;

COMMIT;
