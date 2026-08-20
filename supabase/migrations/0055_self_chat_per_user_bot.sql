-- Self-chat carrier flips from the shared `ipsum` preset to a per-user
-- private bot. Why: in self-chat we want Honcho's *user representation*
-- to fill the standard "## How I observe myself (passive)" slot — i.e.
-- the bot's self-model literally is the user's accumulated peer model.
-- Rendering that as the bot's own representation needs the bot row to be
-- per-user and private; sharing ipsum mixed everyone's self-chat under
-- one bot peer.
--
-- Layout:
--   * Each user owns one private self-bot:
--       slug = 'self-' || user_id  (uuid -> globally unique)
--       creator_id = user_id
--       visibility = 'private'
--       model_id = '~google/gemini-flash-latest'  (OpenRouter "auto-route
--                  variant" prefix; same form as scroll-runner defaults)
--       output_mode = 'bubble'  (self-chat reads as inner-monologue
--                  bubbles; cheap to flip later via creator update)
--   * `open_self_conv()` lazily creates the bot on first call.
--   * Backfill rewires any existing `conversation_type='self'` conv to
--     point at the new per-user bot (conv.bot_id, participants,
--     messages.sender_bot_id). The old ipsum-attributed history becomes
--     attributed to the user's own self-bot — same speaker semantically.

BEGIN;

-- ── 1. Replace open_self_conv: bot is per-user, lazily created ───────
CREATE OR REPLACE FUNCTION pendingbot.open_self_conv() RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pendingbot', 'public'
    AS $$
declare
  caller_id   uuid := auth.uid();
  bot_uuid    uuid;
  conv_id     uuid;
  caller_name text;
  bot_slug    text;
begin
  if caller_id is null then
    raise exception 'auth required';
  end if;

  bot_slug := 'self-' || caller_id::text;

  select coalesce(nullif(display_name, ''), '你') into caller_name
    from pendingbot.users where id = caller_id;

  -- Find or create the per-user self-bot.
  select id into bot_uuid
    from pendingbot.bots
   where slug = bot_slug;

  if bot_uuid is null then
    insert into pendingbot.bots
      (slug, display_name, model_id, output_mode, creator_id, visibility, is_active)
    values
      (bot_slug,
       coalesce(caller_name, '我'),
       '~google/gemini-flash-latest',
       'bubble',
       caller_id,
       'private',
       true)
    returning id into bot_uuid;
  end if;

  -- Reuse if a self conv already exists.
  select id into conv_id
    from pendingbot.conversations
   where user_id = caller_id and conversation_type = 'self'
   limit 1;
  if conv_id is not null then
    return conv_id;
  end if;

  insert into pendingbot.conversations
    (conversation_type, feature, user_id, bot_id, title)
  values
    ('self', 'message', caller_id, bot_uuid, coalesce(caller_name, '我自己'))
  returning id into conv_id;

  insert into pendingbot.conversation_participants
    (conversation_id, participant_type, participant_id, role)
  values
    (conv_id, 'user', caller_id, 'owner'),
    (conv_id, 'bot',  bot_uuid,  'member');

  return conv_id;
end $$;

ALTER FUNCTION pendingbot.open_self_conv() OWNER TO postgres;

-- ── 2. Backfill: rewire existing self convs to per-user bots ─────────
-- Walk every existing self-conv. Mint the user's self-bot if absent,
-- then point the conv (and its participants and message history) at it.
-- We touch sender_bot_id too so the Honcho ingestion attributes past bot
-- replies to bot-${self_bot_id} on next refresh — keeping self-chat's
-- bot-peer history coherent. KV memory regenerates lazily; nothing to
-- evict here.
DO $$
declare
  conv_row   record;
  new_bot_id uuid;
  caller_name text;
  bot_slug   text;
begin
  for conv_row in
    select id, user_id, bot_id
      from pendingbot.conversations
     where conversation_type = 'self'
  loop
    bot_slug := 'self-' || conv_row.user_id::text;

    select id into new_bot_id
      from pendingbot.bots
     where slug = bot_slug;

    if new_bot_id is null then
      select coalesce(nullif(display_name, ''), '你') into caller_name
        from pendingbot.users where id = conv_row.user_id;
      insert into pendingbot.bots
        (slug, display_name, model_id, output_mode, creator_id, visibility, is_active)
      values
        (bot_slug,
         coalesce(caller_name, '我'),
         '~google/gemini-flash-latest',
         'bubble',
         conv_row.user_id,
         'private',
         true)
      returning id into new_bot_id;
    end if;

    -- Already migrated? Skip the rewires.
    if conv_row.bot_id = new_bot_id then
      continue;
    end if;

    update pendingbot.conversations
       set bot_id = new_bot_id, updated_at = now()
     where id = conv_row.id;

    update pendingbot.conversation_participants
       set participant_id = new_bot_id
     where conversation_id = conv_row.id
       and participant_type = 'bot'
       and participant_id = conv_row.bot_id;

    update pendingbot.messages
       set sender_bot_id = new_bot_id
     where conversation_id = conv_row.id
       and sender_bot_id = conv_row.bot_id;
  end loop;
end $$;

COMMIT;
