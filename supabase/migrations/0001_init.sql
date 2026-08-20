-- 0001_init — consolidated PendingBot baseline.
--
-- This file is the squashed schema of the original 0001..0019 chain.
-- It was produced by: bring up an empty Postgres, apply the 19
-- per-feature migrations in order, then `pg_dump --schema-only
-- --schema=pendingbot` and re-attach the cross-schema bits the dump
-- can't see (auth.users trigger, realtime publication, schema grants).
--
-- Conventions:
--   * All app tables live under `pendingbot.*`. The `auth.*` schema is
--     Supabase-managed; we hook it via the `on_auth_user_created`
--     trigger at the bottom.
--   * Primary keys are uuid v7 (`pendingbot.uuidv7()`), monotonic so
--     btree inserts stay hot.
--   * Enum-like columns use text + CHECK constraint so future values
--     can be added without an enum migration.
--   * `pendingbot.is_participant(conv_id)` is `security definer` to
--     avoid RLS recursion when participant policies reference it.
--   * Realtime publication membership is set explicitly at the bottom
--     so the supabase_realtime publication picks up only the tables
--     the iOS / web client subscribe to.
--
-- See seeds/ for preset bots and place_names data.

--


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: pendingbot; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA IF NOT EXISTS pendingbot;


ALTER SCHEMA pendingbot OWNER TO postgres;

--
-- Name: _delete_account_internal(uuid); Type: FUNCTION; Schema: pendingbot; Owner: postgres
--

CREATE FUNCTION pendingbot._delete_account_internal(p_uid uuid) RETURNS void
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

  select coalesce(array_agg(id), '{}') into my_conv_ids
    from pendingbot.conversations where user_id = p_uid;
  select coalesce(array_agg(id), '{}') into my_message_ids
    from pendingbot.messages
   where user_id = p_uid or conversation_id = any(my_conv_ids);

  -- 1. Snip every self-FK pointing at one of our messages.
  update pendingbot.messages set parent_message_id = null
   where parent_message_id = any(my_message_ids);
  update pendingbot.messages set replaces_message_id = null
   where replaces_message_id = any(my_message_ids);
  update pendingbot.messages set replaced_by_message_id = null
   where replaced_by_message_id = any(my_message_ids);

  -- 2. audit_log: preserve rows, decouple user + conv refs.
  update pendingbot.audit_log set conversation_id = null
   where conversation_id = any(my_conv_ids);
  update pendingbot.audit_log set user_id = null where user_id = p_uid;

  -- 3. invites: preserve historical record.
  update pendingbot.invites set created_by = null where created_by = p_uid;
  update pendingbot.invites set used_by = null where used_by = p_uid;

  -- 4. tools: preserve tool definition, disown.
  update pendingbot.tools set owner_id = null where owner_id = p_uid;

  -- 5. NOT-NULL FK rows belonging to the user. Must DELETE.
  delete from pendingbot.skills where owner_id = p_uid;
  delete from pendingbot.attachments where user_id = p_uid;

  -- 6. The user's own messages + participants + convs.
  delete from pendingbot.messages where user_id = p_uid;
  delete from pendingbot.conversation_participants
   where participant_type = 'user' and participant_id = p_uid;
  delete from pendingbot.conversations where user_id = p_uid;

  -- 7. Drop the auth row last; cascades user_unread_counts,
  --    user_handles, user_contacts (both directions), device_tokens,
  --    skill_subscriptions, ai_picks, portraits, bot_reflections,
  --    pendingbot.users, user_settings, user_quota, surf_runs,
  --    review_runs, plus everything else with on-delete-cascade on
  --    auth.users(id).
  delete from auth.users where id = p_uid;
end $$;


ALTER FUNCTION pendingbot._delete_account_internal(p_uid uuid) OWNER TO postgres;

--
-- Name: bootstrap_new_user_trigger(); Type: FUNCTION; Schema: pendingbot; Owner: postgres
--

CREATE FUNCTION pendingbot.bootstrap_new_user_trigger() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
begin
  perform pendingbot.bootstrap_user_id(new.id, new.email, new.raw_user_meta_data);
  return new;
end $$;


ALTER FUNCTION pendingbot.bootstrap_new_user_trigger() OWNER TO postgres;

--
-- Name: bootstrap_user_id(uuid, text, jsonb); Type: FUNCTION; Schema: pendingbot; Owner: postgres
--

CREATE FUNCTION pendingbot.bootstrap_user_id(p_uid uuid, p_email text, p_meta jsonb) RETURNS void
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
    select id, slug, display_name from pendingbot.bots where is_active = true
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


ALTER FUNCTION pendingbot.bootstrap_user_id(p_uid uuid, p_email text, p_meta jsonb) OWNER TO postgres;

--
-- Name: check_handle_limit(); Type: FUNCTION; Schema: pendingbot; Owner: postgres
--

CREATE FUNCTION pendingbot.check_handle_limit() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
declare
  active_count int;
begin
  -- Only count if the new row is active (insert active OR re-activating).
  if not new.is_active then
    return new;
  end if;
  -- For UPDATE re-activating, exclude the current row from the count
  -- (it's about to become active; we count *post* the change).
  select count(*) into active_count
    from pendingbot.user_handles
   where user_id = new.user_id
     and is_active = true
     and (tg_op = 'INSERT' or id <> new.id);
  if active_count >= 5 then
    raise exception 'handle limit: at most 5 active handles per user';
  end if;
  return new;
end $$;


ALTER FUNCTION pendingbot.check_handle_limit() OWNER TO postgres;

--
-- Name: delete_self_account(); Type: FUNCTION; Schema: pendingbot; Owner: postgres
--

CREATE FUNCTION pendingbot.delete_self_account() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pendingbot', 'public', 'auth'
    AS $$
begin
  if auth.uid() is null then
    raise exception 'auth required';
  end if;
  perform pendingbot._delete_account_internal(auth.uid());
end $$;


ALTER FUNCTION pendingbot.delete_self_account() OWNER TO postgres;

--
-- Name: is_participant(uuid); Type: FUNCTION; Schema: pendingbot; Owner: postgres
--

CREATE FUNCTION pendingbot.is_participant(conv_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pendingbot', 'public'
    AS $$
  select exists (
    select 1 from pendingbot.conversation_participants
    where conversation_id = conv_id
      and participant_type = 'user'
      and participant_id = auth.uid()
  );
$$;


ALTER FUNCTION pendingbot.is_participant(conv_id uuid) OWNER TO postgres;

--
-- Name: open_self_conv(); Type: FUNCTION; Schema: pendingbot; Owner: postgres
--

CREATE FUNCTION pendingbot.open_self_conv() RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pendingbot', 'public'
    AS $$
declare
  caller_id uuid := auth.uid();
  bot_uuid  uuid;
  conv_id   uuid;
  caller_name text;
begin
  if caller_id is null then
    raise exception 'auth required';
  end if;

  select id into bot_uuid
    from pendingbot.bots
   where slug = 'ipsum' and is_active = true
   limit 1;
  if bot_uuid is null then
    raise exception 'self-chat bot (slug=ipsum) not configured';
  end if;

  -- Reuse if a self conv already exists for this user.
  select id into conv_id
    from pendingbot.conversations
   where user_id = caller_id and conversation_type = 'self'
   limit 1;
  if conv_id is not null then
    return conv_id;
  end if;

  select coalesce(nullif(display_name, ''), '你') into caller_name
    from pendingbot.users where id = caller_id;

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

--
-- Name: open_user_bot_conv(uuid); Type: FUNCTION; Schema: pendingbot; Owner: postgres
--

CREATE FUNCTION pendingbot.open_user_bot_conv(p_bot_id uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pendingbot', 'public'
    AS $$
declare
  caller_id uuid := auth.uid();
  conv_id   uuid;
begin
  if caller_id is null then
    raise exception 'auth required';
  end if;

  if not exists (select 1 from pendingbot.bots where id = p_bot_id and is_active = true) then
    raise exception 'bot not found or inactive';
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


ALTER FUNCTION pendingbot.open_user_bot_conv(p_bot_id uuid) OWNER TO postgres;

--
-- Name: random_place_name(); Type: FUNCTION; Schema: pendingbot; Owner: postgres
--

CREATE FUNCTION pendingbot.random_place_name() RETURNS text
    LANGUAGE sql
    AS $$
  select name from pendingbot.place_names order by random() limit 1;
$$;


ALTER FUNCTION pendingbot.random_place_name() OWNER TO postgres;

--
-- Name: seed_sample_dialogue(uuid, uuid, uuid, text); Type: FUNCTION; Schema: pendingbot; Owner: postgres
--

CREATE FUNCTION pendingbot.seed_sample_dialogue(p_conv_id uuid, p_user_id uuid, p_bot_id uuid, p_slug text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
declare
  bot_intro text;
  fake_user text;
  bot_followup text;
begin
  if exists (select 1 from pendingbot.messages where conversation_id = p_conv_id) then
    return;
  end if;

  case p_slug
    when 'lorem' then
      bot_intro := '嗨。我是 Lorem，跑在 anthropic/claude-opus-latest。在这里和你聊天的同时，我能联网搜证，事情说不准时会自己去查。';
      fake_user := '蓝鲸的舌头有多重？';
      bot_followup := '一只成年蓝鲸的舌头大约 2.7 吨，相当于一头普通非洲象。这个数字我刚刚顺手查了证。';
    when 'ipsum' then
      bot_intro := '嗨，Ipsum 在这。我擅长写代码、读错误信息、debug。给我一段需求或者贴一段报错都行。';
      fake_user := '用 Python 写一个判断闰年的函数。';
      bot_followup := E'```python\ndef is_leap(y: int) -> bool:\n    return y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)\n```\n标准 Gregorian 规则：被 4 整除，被 100 整除时还得能被 400 整除。';
    when 'dolor' then
      bot_intro := 'Dolor 来了。语气直白，对热点新闻和正在发生的事情比较敏感。说事不说不准的我会自己上网找。';
      fake_user := '最近 AI 圈有什么大新闻？';
      bot_followup := '我刚扫了一圈——现在最显眼的几件：模型迭代节奏在加速、开源社区与商业前沿的差距继续缩小、Agent 落地应用开始多了。哪个方向你想深挖？';
    when 'sit' then
      bot_intro := '你好，我是 Sit。中文长文章扔给我，我能读完帮你抽要点、对比观点、列脉络。';
      fake_user := '我手头一份 30 页的研究报告读不动，怎么办？';
      bot_followup := '把内容贴给我，或者给我能读到的链接。我先压成「主张-论据-缺口」三段，你再决定深入哪一块。';
    when 'amet' then
      bot_intro := 'Amet 在。我擅长把零散的想法整理成清单、表格、流程。"帮我列下..." 这种需求最适合发给我。';
      fake_user := '帮我把今天要做的三件事拆成可执行步骤。';
      bot_followup := '把三件事告诉我，我会按「目标-子任务-时间估算-第一步」四列给你列出来。如果有阻塞依赖我也会标。';
    when 'consectetur' then
      bot_intro := '嗨，我是 Consectetur。擅长写作和创意——从一个标题想出一篇文章，或者从一句话扩展出多种风格的版本。';
      fake_user := '帮我想三个能让别人记住的产品名。';
      bot_followup := '给我一句产品在做什么，我从「偏抽象 / 偏画面感 / 偏隐喻」三个方向各给你 2-3 个候选，然后我们再筛。';
    when 'adipiscing' then
      bot_intro := '我是 Adipiscing。跑在 flash 上，反应快，适合琐碎小问题——查个词、问个时间、确认个细节。';
      fake_user := '一升水多少斤？';
      bot_followup := '1 升水 ≈ 1 公斤 = 2 斤。';
    when 'elit' then
      bot_intro := '我是 Elit。除了和你单聊，PendingBot 还有「议论」——挑几个机器人让我们私下讨论你（你匿名旁听）。要试试吗？';
      fake_user := '怎么用？';
      bot_followup := '消息列表右上 + 号 → 议论 → 选 ≥2 个机器人 + 一个题目。议论只你看得见，你随时可以匿名插话或停止。';
    else
      return;
  end case;

  insert into pendingbot.messages
    (id, client_message_id, conversation_id, sender_bot_id, role, status, content, created_at)
  values
    (pendingbot.uuidv7(), pendingbot.uuidv7(), p_conv_id, p_bot_id, 'bot', 'done', bot_intro, '1970-01-01 00:00:01+00');
  insert into pendingbot.messages
    (id, client_message_id, conversation_id, user_id, role, status, content, created_at)
  values
    (pendingbot.uuidv7(), pendingbot.uuidv7(), p_conv_id, p_user_id, 'user', 'done', fake_user, '1970-01-01 00:00:02+00');
  insert into pendingbot.messages
    (id, client_message_id, conversation_id, sender_bot_id, role, status, content, created_at)
  values
    (pendingbot.uuidv7(), pendingbot.uuidv7(), p_conv_id, p_bot_id, 'bot', 'done', bot_followup, '1970-01-01 00:00:03+00');
end $$;


ALTER FUNCTION pendingbot.seed_sample_dialogue(p_conv_id uuid, p_user_id uuid, p_bot_id uuid, p_slug text) OWNER TO postgres;

--
-- Name: update_unread_counts(); Type: FUNCTION; Schema: pendingbot; Owner: postgres
--

CREATE FUNCTION pendingbot.update_unread_counts() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  -- Don't run for log/system messages or replaced edits.
  if new.role = 'log' or new.status = 'replaced' then
    return new;
  end if;

  insert into pendingbot.user_unread_counts (
    user_id, conversation_id, unread_count,
    last_message_id, last_message_at, last_message_preview
  )
  select
    cp.participant_id,
    new.conversation_id,
    1,
    new.id,
    new.created_at,
    left(coalesce(new.content, ''), 100)
  from pendingbot.conversation_participants cp
  where cp.conversation_id = new.conversation_id
    and cp.participant_type = 'user'
    -- Skip the sender themselves
    and cp.participant_id is distinct from new.user_id
  on conflict (user_id, conversation_id) do update
    set unread_count = pendingbot.user_unread_counts.unread_count + 1,
        last_message_id = new.id,
        last_message_at = new.created_at,
        last_message_preview = left(coalesce(new.content, ''), 100);
  return new;
end;
$$;


ALTER FUNCTION pendingbot.update_unread_counts() OWNER TO postgres;

--
-- Name: uuidv7(); Type: FUNCTION; Schema: pendingbot; Owner: postgres
--

CREATE FUNCTION pendingbot.uuidv7() RETURNS uuid
    LANGUAGE plpgsql
    AS $$
declare
  unix_ts_ms bigint;
  uuid_bytes bytea;
begin
  unix_ts_ms = (extract(epoch from clock_timestamp()) * 1000)::bigint;
  uuid_bytes = extensions.gen_random_bytes(16);
  uuid_bytes = set_byte(uuid_bytes, 0, ((unix_ts_ms >> 40) & 255)::int);
  uuid_bytes = set_byte(uuid_bytes, 1, ((unix_ts_ms >> 32) & 255)::int);
  uuid_bytes = set_byte(uuid_bytes, 2, ((unix_ts_ms >> 24) & 255)::int);
  uuid_bytes = set_byte(uuid_bytes, 3, ((unix_ts_ms >> 16) & 255)::int);
  uuid_bytes = set_byte(uuid_bytes, 4, ((unix_ts_ms >>  8) & 255)::int);
  uuid_bytes = set_byte(uuid_bytes, 5, ( unix_ts_ms        & 255)::int);
  uuid_bytes = set_byte(uuid_bytes, 6, (112 | (get_byte(uuid_bytes, 6) & 15))::int);
  uuid_bytes = set_byte(uuid_bytes, 8, (128 | (get_byte(uuid_bytes, 8) & 63))::int);
  return encode(uuid_bytes, 'hex')::uuid;
end;
$$;


ALTER FUNCTION pendingbot.uuidv7() OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: ai_picks; Type: TABLE; Schema: pendingbot; Owner: postgres
--

CREATE TABLE pendingbot.ai_picks (
    id uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    user_id uuid NOT NULL,
    source text,
    url text,
    title text,
    summary text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE pendingbot.ai_picks OWNER TO postgres;

--
-- Name: attachments; Type: TABLE; Schema: pendingbot; Owner: postgres
--

CREATE TABLE pendingbot.attachments (
    id uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    user_id uuid NOT NULL,
    conversation_id uuid,
    r2_key text NOT NULL,
    thumb_r2_key text,
    mime_type text NOT NULL,
    byte_size integer NOT NULL,
    width integer,
    height integer,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE pendingbot.attachments OWNER TO postgres;

--
-- Name: audit_log; Type: TABLE; Schema: pendingbot; Owner: postgres
--

CREATE TABLE pendingbot.audit_log (
    id uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    user_id uuid,
    conversation_id uuid,
    task_type text NOT NULL,
    model_id text NOT NULL,
    input_tokens integer DEFAULT 0 NOT NULL,
    output_tokens integer DEFAULT 0 NOT NULL,
    total_tokens integer DEFAULT 0 NOT NULL,
    cache_read_tokens integer DEFAULT 0 NOT NULL,
    cache_write_tokens integer DEFAULT 0 NOT NULL,
    cost_usd numeric(12,6),
    generation_id text,
    latency_ms integer,
    tag text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE pendingbot.audit_log OWNER TO postgres;

--
-- Name: bot_lookbacks; Type: TABLE; Schema: pendingbot; Owner: postgres
--

CREATE TABLE pendingbot.bot_lookbacks (
    id uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    conversation_id uuid NOT NULL,
    bot_id uuid NOT NULL,
    body_md text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE pendingbot.bot_lookbacks OWNER TO postgres;

--
-- Name: bot_reflections; Type: TABLE; Schema: pendingbot; Owner: postgres
--

CREATE TABLE pendingbot.bot_reflections (
    id uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    bot_id uuid NOT NULL,
    user_id uuid NOT NULL,
    review_run_id uuid,
    kind text NOT NULL,
    content text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT bot_reflections_kind_check CHECK ((kind = ANY (ARRAY['limit'::text, 'grow'::text, 'keep'::text])))
);


ALTER TABLE pendingbot.bot_reflections OWNER TO postgres;

--
-- Name: bots; Type: TABLE; Schema: pendingbot; Owner: postgres
--

CREATE TABLE pendingbot.bots (
    id uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    slug text NOT NULL,
    display_name text NOT NULL,
    model_id text NOT NULL,
    output_mode text DEFAULT 'single'::text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    config jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT bots_output_mode_check CHECK ((output_mode = ANY (ARRAY['single'::text, 'bubble'::text])))
);


ALTER TABLE pendingbot.bots OWNER TO postgres;

--
-- Name: conversation_participants; Type: TABLE; Schema: pendingbot; Owner: postgres
--

CREATE TABLE pendingbot.conversation_participants (
    conversation_id uuid NOT NULL,
    participant_type text NOT NULL,
    participant_id uuid NOT NULL,
    role text DEFAULT 'member'::text NOT NULL,
    joined_at timestamp with time zone DEFAULT now() NOT NULL,
    last_read_message_id uuid,
    CONSTRAINT conversation_participants_participant_type_check CHECK ((participant_type = ANY (ARRAY['user'::text, 'bot'::text]))),
    CONSTRAINT conversation_participants_role_check CHECK ((role = ANY (ARRAY['owner'::text, 'admin'::text, 'member'::text, 'observer'::text])))
);


ALTER TABLE pendingbot.conversation_participants OWNER TO postgres;

--
-- Name: conversations; Type: TABLE; Schema: pendingbot; Owner: postgres
--

CREATE TABLE pendingbot.conversations (
    id uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    conversation_type text DEFAULT 'user_bot'::text NOT NULL,
    feature text DEFAULT 'message'::text NOT NULL,
    user_id uuid,
    bot_id uuid,
    title text,
    round_count integer DEFAULT 0 NOT NULL,
    last_turn_status text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT conversations_conversation_type_check CHECK ((conversation_type = ANY (ARRAY['user_bot'::text, 'user_user'::text, 'group'::text, 'discuss'::text, 'surf'::text, 'portrait'::text, 'self'::text]))),
    CONSTRAINT conversations_feature_check CHECK ((feature = ANY (ARRAY['message'::text, 'discuss'::text, 'surf'::text, 'portrait'::text])))
);


ALTER TABLE pendingbot.conversations OWNER TO postgres;

--
-- Name: device_tokens; Type: TABLE; Schema: pendingbot; Owner: postgres
--

CREATE TABLE pendingbot.device_tokens (
    id uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    user_id uuid NOT NULL,
    platform text NOT NULL,
    token text NOT NULL,
    endpoint text,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    last_used_at timestamp with time zone,
    CONSTRAINT device_tokens_platform_check CHECK ((platform = ANY (ARRAY['ios'::text, 'web'::text, 'android'::text])))
);


ALTER TABLE pendingbot.device_tokens OWNER TO postgres;

--
-- Name: discuss_settings; Type: TABLE; Schema: pendingbot; Owner: postgres
--

CREATE TABLE pendingbot.discuss_settings (
    bot_id uuid NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    config jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE pendingbot.discuss_settings OWNER TO postgres;

--
-- Name: invites; Type: TABLE; Schema: pendingbot; Owner: postgres
--

CREATE TABLE pendingbot.invites (
    code text NOT NULL,
    created_by uuid,
    used_by uuid,
    used_at timestamp with time zone,
    expires_at timestamp with time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE pendingbot.invites OWNER TO postgres;

--
-- Name: messages; Type: TABLE; Schema: pendingbot; Owner: postgres
--

CREATE TABLE pendingbot.messages (
    id uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    client_message_id uuid NOT NULL,
    conversation_id uuid NOT NULL,
    user_id uuid,
    sender_bot_id uuid,
    role text NOT NULL,
    content text,
    content_partial text,
    status text DEFAULT 'pending'::text NOT NULL,
    stop_requested boolean DEFAULT false NOT NULL,
    replaces_message_id uuid,
    replaced_by_message_id uuid,
    bubble_group_id uuid,
    parent_message_id uuid,
    attachments jsonb,
    log_kind text,
    log_payload jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    content_tsv tsvector GENERATED ALWAYS AS (to_tsvector('simple'::regconfig, COALESCE(content, ''::text))) STORED,
    CONSTRAINT messages_role_check CHECK ((role = ANY (ARRAY['user'::text, 'bot'::text, 'human'::text, 'log'::text]))),
    CONSTRAINT messages_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'streaming'::text, 'done'::text, 'interrupted'::text, 'interrupted_partial'::text, 'error'::text, 'replaced'::text, 'deleted'::text])))
);


ALTER TABLE pendingbot.messages OWNER TO postgres;

--
-- Name: model_pricing; Type: TABLE; Schema: pendingbot; Owner: postgres
--

CREATE TABLE pendingbot.model_pricing (
    model_id text NOT NULL,
    input_price numeric(12,8) NOT NULL,
    cached_input_price numeric(12,8),
    output_price numeric(12,8) NOT NULL,
    currency text DEFAULT 'USD'::text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE pendingbot.model_pricing OWNER TO postgres;

--
-- Name: place_names; Type: TABLE; Schema: pendingbot; Owner: postgres
--

CREATE TABLE pendingbot.place_names (
    name text NOT NULL
);


ALTER TABLE pendingbot.place_names OWNER TO postgres;

--
-- Name: portraits; Type: TABLE; Schema: pendingbot; Owner: postgres
--

CREATE TABLE pendingbot.portraits (
    id uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    user_id uuid NOT NULL,
    conversation_id uuid,
    kind text NOT NULL,
    content jsonb NOT NULL,
    source_summary text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT portraits_kind_check CHECK ((kind = ANY (ARRAY['memos'::text, 'schedule'::text, 'alarms'::text, 'bills'::text, 'moments'::text, 'chat'::text])))
);


ALTER TABLE pendingbot.portraits OWNER TO postgres;

--
-- Name: review_runs; Type: TABLE; Schema: pendingbot; Owner: postgres
--

CREATE TABLE pendingbot.review_runs (
    id uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    conversation_id uuid NOT NULL,
    user_id uuid NOT NULL,
    bot_id uuid NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    trigger text,
    started_at timestamp with time zone,
    finished_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT review_runs_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'running'::text, 'done'::text, 'error'::text, 'cancelled'::text])))
);


ALTER TABLE pendingbot.review_runs OWNER TO postgres;

--
-- Name: skill_subscriptions; Type: TABLE; Schema: pendingbot; Owner: postgres
--

CREATE TABLE pendingbot.skill_subscriptions (
    user_id uuid NOT NULL,
    skill_id uuid NOT NULL,
    conversation_id uuid NOT NULL,
    installed_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE pendingbot.skill_subscriptions OWNER TO postgres;

--
-- Name: skills; Type: TABLE; Schema: pendingbot; Owner: postgres
--

CREATE TABLE pendingbot.skills (
    id uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    owner_id uuid,
    frontmatter jsonb NOT NULL,
    body_md text NOT NULL,
    visibility text DEFAULT 'private'::text NOT NULL,
    forked_from uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    bot_id uuid,
    user_id uuid,
    CONSTRAINT skills_authorship CHECK ((((bot_id IS NOT NULL) AND (user_id IS NOT NULL) AND (owner_id IS NULL)) OR ((bot_id IS NULL) AND (user_id IS NULL) AND (owner_id IS NOT NULL)) OR ((bot_id IS NULL) AND (user_id IS NULL) AND (owner_id IS NULL) AND (visibility = 'public'::text)))),
    CONSTRAINT skills_visibility_check CHECK ((visibility = ANY (ARRAY['private'::text, 'public'::text])))
);


ALTER TABLE pendingbot.skills OWNER TO postgres;

--
-- Name: surf_runs; Type: TABLE; Schema: pendingbot; Owner: postgres
--

CREATE TABLE pendingbot.surf_runs (
    id uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    conversation_id uuid NOT NULL,
    user_id uuid NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    progress jsonb DEFAULT '{}'::jsonb NOT NULL,
    cost_budget_usd numeric(10,4),
    cost_used_usd numeric(10,4) DEFAULT 0 NOT NULL,
    trigger text,
    started_at timestamp with time zone,
    finished_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT surf_runs_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'running'::text, 'done'::text, 'error'::text, 'cancelled'::text])))
);


ALTER TABLE pendingbot.surf_runs OWNER TO postgres;

--
-- Name: tools; Type: TABLE; Schema: pendingbot; Owner: postgres
--

CREATE TABLE pendingbot.tools (
    id uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    owner_id uuid,
    source_type text NOT NULL,
    name text NOT NULL,
    description text,
    schema_json jsonb NOT NULL,
    config_json jsonb,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT tools_source_type_check CHECK ((source_type = ANY (ARRAY['builtin'::text, 'mcp'::text, 'custom'::text])))
);


ALTER TABLE pendingbot.tools OWNER TO postgres;

--
-- Name: user_contacts; Type: TABLE; Schema: pendingbot; Owner: postgres
--

CREATE TABLE pendingbot.user_contacts (
    user_id uuid NOT NULL,
    contact_user_id uuid NOT NULL,
    added_via_handle_id uuid,
    alias text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT user_contacts_check CHECK ((user_id <> contact_user_id))
);


ALTER TABLE pendingbot.user_contacts OWNER TO postgres;

--
-- Name: user_handles; Type: TABLE; Schema: pendingbot; Owner: postgres
--

CREATE TABLE pendingbot.user_handles (
    id uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    user_id uuid NOT NULL,
    kind text DEFAULT 'number'::text NOT NULL,
    value text NOT NULL,
    label text,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    revoked_at timestamp with time zone,
    CONSTRAINT handles_value_format CHECK ((value ~ '^[A-Za-z0-9_-]{4,20}$'::text)),
    CONSTRAINT user_handles_kind_check CHECK ((kind = ANY (ARRAY['number'::text, 'qr'::text])))
);


ALTER TABLE pendingbot.user_handles OWNER TO postgres;

--
-- Name: user_quota; Type: TABLE; Schema: pendingbot; Owner: postgres
--

CREATE TABLE pendingbot.user_quota (
    user_id uuid NOT NULL,
    daily_limit_usd numeric(10,4) DEFAULT 1.0 NOT NULL,
    monthly_limit_usd numeric(10,4) DEFAULT 10.0 NOT NULL,
    daily_used_usd numeric(10,4) DEFAULT 0 NOT NULL,
    monthly_used_usd numeric(10,4) DEFAULT 0 NOT NULL,
    reset_daily_at timestamp with time zone,
    reset_monthly_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE pendingbot.user_quota OWNER TO postgres;

--
-- Name: user_settings; Type: TABLE; Schema: pendingbot; Owner: postgres
--

CREATE TABLE pendingbot.user_settings (
    user_id uuid NOT NULL,
    theme text DEFAULT 'system'::text,
    locale text,
    notifications_enabled boolean DEFAULT true NOT NULL,
    custom_settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT user_settings_theme_check CHECK ((theme = ANY (ARRAY['system'::text, 'light'::text, 'dark'::text])))
);


ALTER TABLE pendingbot.user_settings OWNER TO postgres;

--
-- Name: user_unread_counts; Type: TABLE; Schema: pendingbot; Owner: postgres
--

CREATE TABLE pendingbot.user_unread_counts (
    user_id uuid NOT NULL,
    conversation_id uuid NOT NULL,
    unread_count integer DEFAULT 0 NOT NULL,
    last_message_id uuid,
    last_message_at timestamp with time zone,
    last_message_preview text
);


ALTER TABLE pendingbot.user_unread_counts OWNER TO postgres;

--
-- Name: users; Type: TABLE; Schema: pendingbot; Owner: postgres
--

CREATE TABLE pendingbot.users (
    id uuid NOT NULL,
    display_name text DEFAULT ''::text NOT NULL,
    email text,
    is_admin boolean DEFAULT false NOT NULL,
    bio text DEFAULT ''::text,
    avatar_path text,
    custom_fields jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE pendingbot.users OWNER TO postgres;

--
-- Name: ai_picks ai_picks_pkey; Type: CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.ai_picks
    ADD CONSTRAINT ai_picks_pkey PRIMARY KEY (id);


--
-- Name: attachments attachments_pkey; Type: CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.attachments
    ADD CONSTRAINT attachments_pkey PRIMARY KEY (id);


--
-- Name: audit_log audit_log_pkey; Type: CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.audit_log
    ADD CONSTRAINT audit_log_pkey PRIMARY KEY (id);


--
-- Name: bot_lookbacks bot_lookbacks_pkey; Type: CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.bot_lookbacks
    ADD CONSTRAINT bot_lookbacks_pkey PRIMARY KEY (id);


--
-- Name: bot_reflections bot_reflections_pkey; Type: CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.bot_reflections
    ADD CONSTRAINT bot_reflections_pkey PRIMARY KEY (id);


--
-- Name: bots bots_pkey; Type: CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.bots
    ADD CONSTRAINT bots_pkey PRIMARY KEY (id);


--
-- Name: bots bots_slug_key; Type: CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.bots
    ADD CONSTRAINT bots_slug_key UNIQUE (slug);


--
-- Name: conversation_participants conversation_participants_pkey; Type: CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.conversation_participants
    ADD CONSTRAINT conversation_participants_pkey PRIMARY KEY (conversation_id, participant_type, participant_id);


--
-- Name: conversations conversations_pkey; Type: CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.conversations
    ADD CONSTRAINT conversations_pkey PRIMARY KEY (id);


--
-- Name: device_tokens device_tokens_pkey; Type: CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.device_tokens
    ADD CONSTRAINT device_tokens_pkey PRIMARY KEY (id);


--
-- Name: device_tokens device_tokens_user_id_token_key; Type: CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.device_tokens
    ADD CONSTRAINT device_tokens_user_id_token_key UNIQUE (user_id, token);


--
-- Name: discuss_settings discuss_settings_pkey; Type: CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.discuss_settings
    ADD CONSTRAINT discuss_settings_pkey PRIMARY KEY (bot_id);


--
-- Name: invites invites_pkey; Type: CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.invites
    ADD CONSTRAINT invites_pkey PRIMARY KEY (code);


--
-- Name: messages messages_client_message_id_key; Type: CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.messages
    ADD CONSTRAINT messages_client_message_id_key UNIQUE (client_message_id);


--
-- Name: messages messages_pkey; Type: CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.messages
    ADD CONSTRAINT messages_pkey PRIMARY KEY (id);


--
-- Name: model_pricing model_pricing_pkey; Type: CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.model_pricing
    ADD CONSTRAINT model_pricing_pkey PRIMARY KEY (model_id);


--
-- Name: place_names place_names_pkey; Type: CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.place_names
    ADD CONSTRAINT place_names_pkey PRIMARY KEY (name);


--
-- Name: portraits portraits_pkey; Type: CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.portraits
    ADD CONSTRAINT portraits_pkey PRIMARY KEY (id);


--
-- Name: review_runs review_runs_pkey; Type: CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.review_runs
    ADD CONSTRAINT review_runs_pkey PRIMARY KEY (id);


--
-- Name: skill_subscriptions skill_subscriptions_pkey; Type: CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.skill_subscriptions
    ADD CONSTRAINT skill_subscriptions_pkey PRIMARY KEY (user_id, skill_id, conversation_id);


--
-- Name: skills skills_pkey; Type: CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.skills
    ADD CONSTRAINT skills_pkey PRIMARY KEY (id);


--
-- Name: surf_runs surf_runs_pkey; Type: CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.surf_runs
    ADD CONSTRAINT surf_runs_pkey PRIMARY KEY (id);


--
-- Name: tools tools_pkey; Type: CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.tools
    ADD CONSTRAINT tools_pkey PRIMARY KEY (id);


--
-- Name: user_contacts user_contacts_pkey; Type: CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.user_contacts
    ADD CONSTRAINT user_contacts_pkey PRIMARY KEY (user_id, contact_user_id);


--
-- Name: user_handles user_handles_pkey; Type: CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.user_handles
    ADD CONSTRAINT user_handles_pkey PRIMARY KEY (id);


--
-- Name: user_handles user_handles_value_key; Type: CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.user_handles
    ADD CONSTRAINT user_handles_value_key UNIQUE (value);


--
-- Name: user_quota user_quota_pkey; Type: CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.user_quota
    ADD CONSTRAINT user_quota_pkey PRIMARY KEY (user_id);


--
-- Name: user_settings user_settings_pkey; Type: CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.user_settings
    ADD CONSTRAINT user_settings_pkey PRIMARY KEY (user_id);


--
-- Name: user_unread_counts user_unread_counts_pkey; Type: CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.user_unread_counts
    ADD CONSTRAINT user_unread_counts_pkey PRIMARY KEY (user_id, conversation_id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: idx_ai_picks_user_time; Type: INDEX; Schema: pendingbot; Owner: postgres
--

CREATE INDEX idx_ai_picks_user_time ON pendingbot.ai_picks USING btree (user_id, created_at DESC);


--
-- Name: idx_attachments_conv; Type: INDEX; Schema: pendingbot; Owner: postgres
--

CREATE INDEX idx_attachments_conv ON pendingbot.attachments USING btree (conversation_id);


--
-- Name: idx_audit_model_time; Type: INDEX; Schema: pendingbot; Owner: postgres
--

CREATE INDEX idx_audit_model_time ON pendingbot.audit_log USING btree (model_id, created_at DESC);


--
-- Name: idx_audit_user_time; Type: INDEX; Schema: pendingbot; Owner: postgres
--

CREATE INDEX idx_audit_user_time ON pendingbot.audit_log USING btree (user_id, created_at DESC);


--
-- Name: idx_contacts_contact; Type: INDEX; Schema: pendingbot; Owner: postgres
--

CREATE INDEX idx_contacts_contact ON pendingbot.user_contacts USING btree (contact_user_id);


--
-- Name: idx_conversations_user_updated; Type: INDEX; Schema: pendingbot; Owner: postgres
--

CREATE INDEX idx_conversations_user_updated ON pendingbot.conversations USING btree (user_id, updated_at DESC) WHERE (user_id IS NOT NULL);


--
-- Name: idx_handles_user_active; Type: INDEX; Schema: pendingbot; Owner: postgres
--

CREATE INDEX idx_handles_user_active ON pendingbot.user_handles USING btree (user_id, is_active);


--
-- Name: idx_lookbacks_conv_active; Type: INDEX; Schema: pendingbot; Owner: postgres
--

CREATE INDEX idx_lookbacks_conv_active ON pendingbot.bot_lookbacks USING btree (conversation_id, active, created_at DESC);


--
-- Name: idx_messages_conv_time; Type: INDEX; Schema: pendingbot; Owner: postgres
--

CREATE INDEX idx_messages_conv_time ON pendingbot.messages USING btree (conversation_id, created_at DESC);


--
-- Name: idx_messages_search; Type: INDEX; Schema: pendingbot; Owner: postgres
--

CREATE INDEX idx_messages_search ON pendingbot.messages USING gin (content_tsv);


--
-- Name: idx_messages_user_time; Type: INDEX; Schema: pendingbot; Owner: postgres
--

CREATE INDEX idx_messages_user_time ON pendingbot.messages USING btree (user_id, created_at DESC) WHERE (user_id IS NOT NULL);


--
-- Name: idx_participants_bot; Type: INDEX; Schema: pendingbot; Owner: postgres
--

CREATE INDEX idx_participants_bot ON pendingbot.conversation_participants USING btree (participant_id) WHERE (participant_type = 'bot'::text);


--
-- Name: idx_participants_user; Type: INDEX; Schema: pendingbot; Owner: postgres
--

CREATE INDEX idx_participants_user ON pendingbot.conversation_participants USING btree (participant_id) WHERE (participant_type = 'user'::text);


--
-- Name: idx_portraits_user_kind_time; Type: INDEX; Schema: pendingbot; Owner: postgres
--

CREATE INDEX idx_portraits_user_kind_time ON pendingbot.portraits USING btree (user_id, kind, created_at DESC);


--
-- Name: idx_reflections_bot_user_time; Type: INDEX; Schema: pendingbot; Owner: postgres
--

CREATE INDEX idx_reflections_bot_user_time ON pendingbot.bot_reflections USING btree (bot_id, user_id, created_at DESC);


--
-- Name: idx_review_runs_conv; Type: INDEX; Schema: pendingbot; Owner: postgres
--

CREATE INDEX idx_review_runs_conv ON pendingbot.review_runs USING btree (conversation_id);


--
-- Name: idx_skills_bot_user; Type: INDEX; Schema: pendingbot; Owner: postgres
--

CREATE INDEX idx_skills_bot_user ON pendingbot.skills USING btree (bot_id, user_id) WHERE (bot_id IS NOT NULL);


--
-- Name: idx_skills_owner; Type: INDEX; Schema: pendingbot; Owner: postgres
--

CREATE INDEX idx_skills_owner ON pendingbot.skills USING btree (owner_id);


--
-- Name: idx_skills_public; Type: INDEX; Schema: pendingbot; Owner: postgres
--

CREATE INDEX idx_skills_public ON pendingbot.skills USING btree (visibility) WHERE (visibility = 'public'::text);


--
-- Name: idx_surf_runs_conv; Type: INDEX; Schema: pendingbot; Owner: postgres
--

CREATE INDEX idx_surf_runs_conv ON pendingbot.surf_runs USING btree (conversation_id);


--
-- Name: user_handles handles_limit; Type: TRIGGER; Schema: pendingbot; Owner: postgres
--

CREATE TRIGGER handles_limit BEFORE INSERT OR UPDATE ON pendingbot.user_handles FOR EACH ROW EXECUTE FUNCTION pendingbot.check_handle_limit();


--
-- Name: messages messages_unread_after_insert; Type: TRIGGER; Schema: pendingbot; Owner: postgres
--

CREATE TRIGGER messages_unread_after_insert AFTER INSERT ON pendingbot.messages FOR EACH ROW EXECUTE FUNCTION pendingbot.update_unread_counts();


--
-- Name: ai_picks ai_picks_user_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.ai_picks
    ADD CONSTRAINT ai_picks_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: attachments attachments_conversation_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.attachments
    ADD CONSTRAINT attachments_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES pendingbot.conversations(id) ON DELETE CASCADE;


--
-- Name: attachments attachments_user_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.attachments
    ADD CONSTRAINT attachments_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id);


--
-- Name: audit_log audit_log_conversation_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.audit_log
    ADD CONSTRAINT audit_log_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES pendingbot.conversations(id);


--
-- Name: audit_log audit_log_user_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.audit_log
    ADD CONSTRAINT audit_log_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id);


--
-- Name: bot_lookbacks bot_lookbacks_bot_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.bot_lookbacks
    ADD CONSTRAINT bot_lookbacks_bot_id_fkey FOREIGN KEY (bot_id) REFERENCES pendingbot.bots(id) ON DELETE CASCADE;


--
-- Name: bot_lookbacks bot_lookbacks_conversation_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.bot_lookbacks
    ADD CONSTRAINT bot_lookbacks_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES pendingbot.conversations(id) ON DELETE CASCADE;


--
-- Name: bot_reflections bot_reflections_bot_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.bot_reflections
    ADD CONSTRAINT bot_reflections_bot_id_fkey FOREIGN KEY (bot_id) REFERENCES pendingbot.bots(id) ON DELETE CASCADE;


--
-- Name: bot_reflections bot_reflections_user_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.bot_reflections
    ADD CONSTRAINT bot_reflections_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: conversation_participants conversation_participants_conversation_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.conversation_participants
    ADD CONSTRAINT conversation_participants_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES pendingbot.conversations(id) ON DELETE CASCADE;


--
-- Name: conversations conversations_bot_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.conversations
    ADD CONSTRAINT conversations_bot_id_fkey FOREIGN KEY (bot_id) REFERENCES pendingbot.bots(id);


--
-- Name: conversations conversations_user_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.conversations
    ADD CONSTRAINT conversations_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id);


--
-- Name: device_tokens device_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.device_tokens
    ADD CONSTRAINT device_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: discuss_settings discuss_settings_bot_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.discuss_settings
    ADD CONSTRAINT discuss_settings_bot_id_fkey FOREIGN KEY (bot_id) REFERENCES pendingbot.bots(id) ON DELETE CASCADE;


--
-- Name: invites invites_created_by_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.invites
    ADD CONSTRAINT invites_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: invites invites_used_by_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.invites
    ADD CONSTRAINT invites_used_by_fkey FOREIGN KEY (used_by) REFERENCES auth.users(id);


--
-- Name: messages messages_conversation_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.messages
    ADD CONSTRAINT messages_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES pendingbot.conversations(id) ON DELETE CASCADE;


--
-- Name: messages messages_parent_message_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.messages
    ADD CONSTRAINT messages_parent_message_id_fkey FOREIGN KEY (parent_message_id) REFERENCES pendingbot.messages(id);


--
-- Name: messages messages_replaced_by_message_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.messages
    ADD CONSTRAINT messages_replaced_by_message_id_fkey FOREIGN KEY (replaced_by_message_id) REFERENCES pendingbot.messages(id);


--
-- Name: messages messages_replaces_message_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.messages
    ADD CONSTRAINT messages_replaces_message_id_fkey FOREIGN KEY (replaces_message_id) REFERENCES pendingbot.messages(id);


--
-- Name: messages messages_sender_bot_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.messages
    ADD CONSTRAINT messages_sender_bot_id_fkey FOREIGN KEY (sender_bot_id) REFERENCES pendingbot.bots(id);


--
-- Name: messages messages_user_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.messages
    ADD CONSTRAINT messages_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id);


--
-- Name: portraits portraits_conversation_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.portraits
    ADD CONSTRAINT portraits_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES pendingbot.conversations(id) ON DELETE CASCADE;


--
-- Name: portraits portraits_user_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.portraits
    ADD CONSTRAINT portraits_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: review_runs review_runs_bot_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.review_runs
    ADD CONSTRAINT review_runs_bot_id_fkey FOREIGN KEY (bot_id) REFERENCES pendingbot.bots(id);


--
-- Name: review_runs review_runs_conversation_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.review_runs
    ADD CONSTRAINT review_runs_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES pendingbot.conversations(id) ON DELETE CASCADE;


--
-- Name: review_runs review_runs_user_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.review_runs
    ADD CONSTRAINT review_runs_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: skill_subscriptions skill_subscriptions_conversation_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.skill_subscriptions
    ADD CONSTRAINT skill_subscriptions_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES pendingbot.conversations(id) ON DELETE CASCADE;


--
-- Name: skill_subscriptions skill_subscriptions_skill_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.skill_subscriptions
    ADD CONSTRAINT skill_subscriptions_skill_id_fkey FOREIGN KEY (skill_id) REFERENCES pendingbot.skills(id) ON DELETE CASCADE;


--
-- Name: skill_subscriptions skill_subscriptions_user_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.skill_subscriptions
    ADD CONSTRAINT skill_subscriptions_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: skills skills_bot_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.skills
    ADD CONSTRAINT skills_bot_id_fkey FOREIGN KEY (bot_id) REFERENCES pendingbot.bots(id) ON DELETE CASCADE;


--
-- Name: skills skills_forked_from_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.skills
    ADD CONSTRAINT skills_forked_from_fkey FOREIGN KEY (forked_from) REFERENCES pendingbot.skills(id);


--
-- Name: skills skills_owner_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.skills
    ADD CONSTRAINT skills_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES auth.users(id);


--
-- Name: skills skills_user_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.skills
    ADD CONSTRAINT skills_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: surf_runs surf_runs_conversation_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.surf_runs
    ADD CONSTRAINT surf_runs_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES pendingbot.conversations(id) ON DELETE CASCADE;


--
-- Name: surf_runs surf_runs_user_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.surf_runs
    ADD CONSTRAINT surf_runs_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: tools tools_owner_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.tools
    ADD CONSTRAINT tools_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES auth.users(id);


--
-- Name: user_contacts user_contacts_added_via_handle_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.user_contacts
    ADD CONSTRAINT user_contacts_added_via_handle_id_fkey FOREIGN KEY (added_via_handle_id) REFERENCES pendingbot.user_handles(id) ON DELETE SET NULL;


--
-- Name: user_contacts user_contacts_contact_user_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.user_contacts
    ADD CONSTRAINT user_contacts_contact_user_id_fkey FOREIGN KEY (contact_user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: user_contacts user_contacts_user_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.user_contacts
    ADD CONSTRAINT user_contacts_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: user_handles user_handles_user_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.user_handles
    ADD CONSTRAINT user_handles_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: user_quota user_quota_user_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.user_quota
    ADD CONSTRAINT user_quota_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: user_settings user_settings_user_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.user_settings
    ADD CONSTRAINT user_settings_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: user_unread_counts user_unread_counts_conversation_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.user_unread_counts
    ADD CONSTRAINT user_unread_counts_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES pendingbot.conversations(id) ON DELETE CASCADE;


--
-- Name: user_unread_counts user_unread_counts_user_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.user_unread_counts
    ADD CONSTRAINT user_unread_counts_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: users users_id_fkey; Type: FK CONSTRAINT; Schema: pendingbot; Owner: postgres
--

ALTER TABLE ONLY pendingbot.users
    ADD CONSTRAINT users_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: ai_picks; Type: ROW SECURITY; Schema: pendingbot; Owner: postgres
--

ALTER TABLE pendingbot.ai_picks ENABLE ROW LEVEL SECURITY;

--
-- Name: attachments; Type: ROW SECURITY; Schema: pendingbot; Owner: postgres
--

ALTER TABLE pendingbot.attachments ENABLE ROW LEVEL SECURITY;

--
-- Name: attachments attachments_self_insert; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY attachments_self_insert ON pendingbot.attachments FOR INSERT WITH CHECK ((user_id = auth.uid()));


--
-- Name: attachments attachments_self_read; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY attachments_self_read ON pendingbot.attachments FOR SELECT USING (((user_id = auth.uid()) OR ((conversation_id IS NOT NULL) AND pendingbot.is_participant(conversation_id))));


--
-- Name: audit_log; Type: ROW SECURITY; Schema: pendingbot; Owner: postgres
--

ALTER TABLE pendingbot.audit_log ENABLE ROW LEVEL SECURITY;

--
-- Name: bot_lookbacks; Type: ROW SECURITY; Schema: pendingbot; Owner: postgres
--

ALTER TABLE pendingbot.bot_lookbacks ENABLE ROW LEVEL SECURITY;

--
-- Name: bot_reflections; Type: ROW SECURITY; Schema: pendingbot; Owner: postgres
--

ALTER TABLE pendingbot.bot_reflections ENABLE ROW LEVEL SECURITY;

--
-- Name: bots; Type: ROW SECURITY; Schema: pendingbot; Owner: postgres
--

ALTER TABLE pendingbot.bots ENABLE ROW LEVEL SECURITY;

--
-- Name: bots bots_authenticated_read; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY bots_authenticated_read ON pendingbot.bots FOR SELECT USING ((auth.role() = 'authenticated'::text));


--
-- Name: user_contacts contacts_self_delete; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY contacts_self_delete ON pendingbot.user_contacts FOR DELETE USING ((user_id = auth.uid()));


--
-- Name: user_contacts contacts_self_read; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY contacts_self_read ON pendingbot.user_contacts FOR SELECT USING ((user_id = auth.uid()));


--
-- Name: user_contacts contacts_self_update; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY contacts_self_update ON pendingbot.user_contacts FOR UPDATE USING ((user_id = auth.uid())) WITH CHECK ((user_id = auth.uid()));


--
-- Name: conversation_participants; Type: ROW SECURITY; Schema: pendingbot; Owner: postgres
--

ALTER TABLE pendingbot.conversation_participants ENABLE ROW LEVEL SECURITY;

--
-- Name: conversations; Type: ROW SECURITY; Schema: pendingbot; Owner: postgres
--

ALTER TABLE pendingbot.conversations ENABLE ROW LEVEL SECURITY;

--
-- Name: conversations conversations_owner_update; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY conversations_owner_update ON pendingbot.conversations FOR UPDATE USING ((user_id = auth.uid()));


--
-- Name: conversations conversations_owner_write; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY conversations_owner_write ON pendingbot.conversations FOR INSERT WITH CHECK ((user_id = auth.uid()));


--
-- Name: conversations conversations_participant_read; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY conversations_participant_read ON pendingbot.conversations FOR SELECT USING (pendingbot.is_participant(id));


--
-- Name: device_tokens; Type: ROW SECURITY; Schema: pendingbot; Owner: postgres
--

ALTER TABLE pendingbot.device_tokens ENABLE ROW LEVEL SECURITY;

--
-- Name: device_tokens devices_self; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY devices_self ON pendingbot.device_tokens USING ((user_id = auth.uid())) WITH CHECK ((user_id = auth.uid()));


--
-- Name: discuss_settings; Type: ROW SECURITY; Schema: pendingbot; Owner: postgres
--

ALTER TABLE pendingbot.discuss_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: user_handles handles_owner_delete; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY handles_owner_delete ON pendingbot.user_handles FOR DELETE USING ((user_id = auth.uid()));


--
-- Name: user_handles handles_owner_read; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY handles_owner_read ON pendingbot.user_handles FOR SELECT USING ((user_id = auth.uid()));


--
-- Name: user_handles handles_owner_update; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY handles_owner_update ON pendingbot.user_handles FOR UPDATE USING ((user_id = auth.uid())) WITH CHECK ((user_id = auth.uid()));


--
-- Name: user_handles handles_owner_write; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY handles_owner_write ON pendingbot.user_handles FOR INSERT WITH CHECK ((user_id = auth.uid()));


--
-- Name: invites; Type: ROW SECURITY; Schema: pendingbot; Owner: postgres
--

ALTER TABLE pendingbot.invites ENABLE ROW LEVEL SECURITY;

--
-- Name: bot_lookbacks lookbacks_participant_read; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY lookbacks_participant_read ON pendingbot.bot_lookbacks FOR SELECT USING (pendingbot.is_participant(conversation_id));


--
-- Name: messages; Type: ROW SECURITY; Schema: pendingbot; Owner: postgres
--

ALTER TABLE pendingbot.messages ENABLE ROW LEVEL SECURITY;

--
-- Name: messages messages_participant_insert; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY messages_participant_insert ON pendingbot.messages FOR INSERT WITH CHECK ((pendingbot.is_participant(conversation_id) AND (((role = 'user'::text) AND (user_id = auth.uid())) OR ((role = 'human'::text) AND (user_id = auth.uid())) OR (role = 'log'::text))));


--
-- Name: messages messages_participant_read; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY messages_participant_read ON pendingbot.messages FOR SELECT USING (pendingbot.is_participant(conversation_id));


--
-- Name: messages messages_self_update; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY messages_self_update ON pendingbot.messages FOR UPDATE USING (((user_id = auth.uid()) AND (role = ANY (ARRAY['user'::text, 'human'::text]))));


--
-- Name: model_pricing; Type: ROW SECURITY; Schema: pendingbot; Owner: postgres
--

ALTER TABLE pendingbot.model_pricing ENABLE ROW LEVEL SECURITY;

--
-- Name: conversation_participants participants_owner_seed; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY participants_owner_seed ON pendingbot.conversation_participants FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM pendingbot.conversations
  WHERE ((conversations.id = conversation_participants.conversation_id) AND (conversations.user_id = auth.uid())))));


--
-- Name: conversation_participants participants_self_read; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY participants_self_read ON pendingbot.conversation_participants FOR SELECT USING ((((participant_type = 'user'::text) AND (participant_id = auth.uid())) OR pendingbot.is_participant(conversation_id)));


--
-- Name: ai_picks picks_self; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY picks_self ON pendingbot.ai_picks FOR SELECT USING ((user_id = auth.uid()));


--
-- Name: place_names; Type: ROW SECURITY; Schema: pendingbot; Owner: postgres
--

ALTER TABLE pendingbot.place_names ENABLE ROW LEVEL SECURITY;

--
-- Name: place_names place_names_authenticated_read; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY place_names_authenticated_read ON pendingbot.place_names FOR SELECT USING ((auth.role() = 'authenticated'::text));


--
-- Name: portraits; Type: ROW SECURITY; Schema: pendingbot; Owner: postgres
--

ALTER TABLE pendingbot.portraits ENABLE ROW LEVEL SECURITY;

--
-- Name: portraits portraits_self; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY portraits_self ON pendingbot.portraits FOR SELECT USING ((user_id = auth.uid()));


--
-- Name: user_quota quota_self_read; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY quota_self_read ON pendingbot.user_quota FOR SELECT USING ((user_id = auth.uid()));


--
-- Name: review_runs; Type: ROW SECURITY; Schema: pendingbot; Owner: postgres
--

ALTER TABLE pendingbot.review_runs ENABLE ROW LEVEL SECURITY;

--
-- Name: review_runs review_self; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY review_self ON pendingbot.review_runs FOR SELECT USING ((user_id = auth.uid()));


--
-- Name: user_settings settings_self; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY settings_self ON pendingbot.user_settings USING ((user_id = auth.uid())) WITH CHECK ((user_id = auth.uid()));


--
-- Name: skill_subscriptions skill_subs_self; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY skill_subs_self ON pendingbot.skill_subscriptions USING ((user_id = auth.uid())) WITH CHECK ((user_id = auth.uid()));


--
-- Name: skill_subscriptions; Type: ROW SECURITY; Schema: pendingbot; Owner: postgres
--

ALTER TABLE pendingbot.skill_subscriptions ENABLE ROW LEVEL SECURITY;

--
-- Name: skills; Type: ROW SECURITY; Schema: pendingbot; Owner: postgres
--

ALTER TABLE pendingbot.skills ENABLE ROW LEVEL SECURITY;

--
-- Name: skills skills_read; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY skills_read ON pendingbot.skills FOR SELECT USING (((owner_id = auth.uid()) OR ((bot_id IS NULL) AND (visibility = 'public'::text))));


--
-- Name: skills skills_user_delete; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY skills_user_delete ON pendingbot.skills FOR DELETE USING (((owner_id = auth.uid()) AND (bot_id IS NULL)));


--
-- Name: skills skills_user_insert; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY skills_user_insert ON pendingbot.skills FOR INSERT WITH CHECK (((owner_id = auth.uid()) AND (bot_id IS NULL) AND (user_id IS NULL)));


--
-- Name: skills skills_user_update; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY skills_user_update ON pendingbot.skills FOR UPDATE USING (((owner_id = auth.uid()) AND (bot_id IS NULL))) WITH CHECK (((owner_id = auth.uid()) AND (bot_id IS NULL)));


--
-- Name: surf_runs; Type: ROW SECURITY; Schema: pendingbot; Owner: postgres
--

ALTER TABLE pendingbot.surf_runs ENABLE ROW LEVEL SECURITY;

--
-- Name: surf_runs surf_self; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY surf_self ON pendingbot.surf_runs FOR SELECT USING ((user_id = auth.uid()));


--
-- Name: tools; Type: ROW SECURITY; Schema: pendingbot; Owner: postgres
--

ALTER TABLE pendingbot.tools ENABLE ROW LEVEL SECURITY;

--
-- Name: tools tools_visible; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY tools_visible ON pendingbot.tools FOR SELECT USING (((owner_id IS NULL) OR (owner_id = auth.uid())));


--
-- Name: user_unread_counts unread_self_read; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY unread_self_read ON pendingbot.user_unread_counts FOR SELECT USING ((user_id = auth.uid()));


--
-- Name: user_unread_counts unread_self_update; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY unread_self_update ON pendingbot.user_unread_counts FOR UPDATE USING ((user_id = auth.uid()));


--
-- Name: user_contacts; Type: ROW SECURITY; Schema: pendingbot; Owner: postgres
--

ALTER TABLE pendingbot.user_contacts ENABLE ROW LEVEL SECURITY;

--
-- Name: user_handles; Type: ROW SECURITY; Schema: pendingbot; Owner: postgres
--

ALTER TABLE pendingbot.user_handles ENABLE ROW LEVEL SECURITY;

--
-- Name: user_quota; Type: ROW SECURITY; Schema: pendingbot; Owner: postgres
--

ALTER TABLE pendingbot.user_quota ENABLE ROW LEVEL SECURITY;

--
-- Name: user_settings; Type: ROW SECURITY; Schema: pendingbot; Owner: postgres
--

ALTER TABLE pendingbot.user_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: user_unread_counts; Type: ROW SECURITY; Schema: pendingbot; Owner: postgres
--

ALTER TABLE pendingbot.user_unread_counts ENABLE ROW LEVEL SECURITY;

--
-- Name: users; Type: ROW SECURITY; Schema: pendingbot; Owner: postgres
--

ALTER TABLE pendingbot.users ENABLE ROW LEVEL SECURITY;

--
-- Name: users users_self_read; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY users_self_read ON pendingbot.users FOR SELECT USING ((id = auth.uid()));


--
-- Name: users users_self_update; Type: POLICY; Schema: pendingbot; Owner: postgres
--

CREATE POLICY users_self_update ON pendingbot.users FOR UPDATE USING ((id = auth.uid()));


--
-- Name: SCHEMA pendingbot; Type: ACL; Schema: -; Owner: postgres
--

GRANT USAGE ON SCHEMA pendingbot TO authenticated;
GRANT USAGE ON SCHEMA pendingbot TO anon;
GRANT USAGE ON SCHEMA pendingbot TO service_role;


--
-- Name: FUNCTION _delete_account_internal(p_uid uuid); Type: ACL; Schema: pendingbot; Owner: postgres
--

REVOKE ALL ON FUNCTION pendingbot._delete_account_internal(p_uid uuid) FROM PUBLIC;


--
-- Name: FUNCTION delete_self_account(); Type: ACL; Schema: pendingbot; Owner: postgres
--

GRANT ALL ON FUNCTION pendingbot.delete_self_account() TO authenticated;


--
-- Name: FUNCTION is_participant(conv_id uuid); Type: ACL; Schema: pendingbot; Owner: postgres
--

GRANT ALL ON FUNCTION pendingbot.is_participant(conv_id uuid) TO authenticated;


--
-- Name: FUNCTION open_self_conv(); Type: ACL; Schema: pendingbot; Owner: postgres
--

GRANT ALL ON FUNCTION pendingbot.open_self_conv() TO authenticated;


--
-- Name: FUNCTION open_user_bot_conv(p_bot_id uuid); Type: ACL; Schema: pendingbot; Owner: postgres
--

GRANT ALL ON FUNCTION pendingbot.open_user_bot_conv(p_bot_id uuid) TO authenticated;


--
-- Name: FUNCTION random_place_name(); Type: ACL; Schema: pendingbot; Owner: postgres
--

GRANT ALL ON FUNCTION pendingbot.random_place_name() TO authenticated;


--
-- Name: TABLE ai_picks; Type: ACL; Schema: pendingbot; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.ai_picks TO authenticated;
GRANT SELECT ON TABLE pendingbot.ai_picks TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.ai_picks TO service_role;


--
-- Name: TABLE attachments; Type: ACL; Schema: pendingbot; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.attachments TO authenticated;
GRANT SELECT ON TABLE pendingbot.attachments TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.attachments TO service_role;


--
-- Name: TABLE audit_log; Type: ACL; Schema: pendingbot; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.audit_log TO authenticated;
GRANT SELECT ON TABLE pendingbot.audit_log TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.audit_log TO service_role;


--
-- Name: TABLE bot_lookbacks; Type: ACL; Schema: pendingbot; Owner: postgres
--

GRANT SELECT ON TABLE pendingbot.bot_lookbacks TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.bot_lookbacks TO authenticated;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.bot_lookbacks TO service_role;


--
-- Name: TABLE bot_reflections; Type: ACL; Schema: pendingbot; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.bot_reflections TO authenticated;
GRANT SELECT ON TABLE pendingbot.bot_reflections TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.bot_reflections TO service_role;


--
-- Name: TABLE bots; Type: ACL; Schema: pendingbot; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.bots TO authenticated;
GRANT SELECT ON TABLE pendingbot.bots TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.bots TO service_role;


--
-- Name: TABLE conversation_participants; Type: ACL; Schema: pendingbot; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.conversation_participants TO authenticated;
GRANT SELECT ON TABLE pendingbot.conversation_participants TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.conversation_participants TO service_role;


--
-- Name: TABLE conversations; Type: ACL; Schema: pendingbot; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.conversations TO authenticated;
GRANT SELECT ON TABLE pendingbot.conversations TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.conversations TO service_role;


--
-- Name: TABLE device_tokens; Type: ACL; Schema: pendingbot; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.device_tokens TO authenticated;
GRANT SELECT ON TABLE pendingbot.device_tokens TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.device_tokens TO service_role;


--
-- Name: TABLE discuss_settings; Type: ACL; Schema: pendingbot; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.discuss_settings TO authenticated;
GRANT SELECT ON TABLE pendingbot.discuss_settings TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.discuss_settings TO service_role;


--
-- Name: TABLE invites; Type: ACL; Schema: pendingbot; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.invites TO authenticated;
GRANT SELECT ON TABLE pendingbot.invites TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.invites TO service_role;


--
-- Name: TABLE messages; Type: ACL; Schema: pendingbot; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.messages TO authenticated;
GRANT SELECT ON TABLE pendingbot.messages TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.messages TO service_role;


--
-- Name: TABLE model_pricing; Type: ACL; Schema: pendingbot; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.model_pricing TO authenticated;
GRANT SELECT ON TABLE pendingbot.model_pricing TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.model_pricing TO service_role;


--
-- Name: TABLE place_names; Type: ACL; Schema: pendingbot; Owner: postgres
--

GRANT SELECT ON TABLE pendingbot.place_names TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.place_names TO authenticated;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.place_names TO service_role;


--
-- Name: TABLE portraits; Type: ACL; Schema: pendingbot; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.portraits TO authenticated;
GRANT SELECT ON TABLE pendingbot.portraits TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.portraits TO service_role;


--
-- Name: TABLE review_runs; Type: ACL; Schema: pendingbot; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.review_runs TO authenticated;
GRANT SELECT ON TABLE pendingbot.review_runs TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.review_runs TO service_role;


--
-- Name: TABLE skill_subscriptions; Type: ACL; Schema: pendingbot; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.skill_subscriptions TO authenticated;
GRANT SELECT ON TABLE pendingbot.skill_subscriptions TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.skill_subscriptions TO service_role;


--
-- Name: TABLE skills; Type: ACL; Schema: pendingbot; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.skills TO authenticated;
GRANT SELECT ON TABLE pendingbot.skills TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.skills TO service_role;


--
-- Name: TABLE surf_runs; Type: ACL; Schema: pendingbot; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.surf_runs TO authenticated;
GRANT SELECT ON TABLE pendingbot.surf_runs TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.surf_runs TO service_role;


--
-- Name: TABLE tools; Type: ACL; Schema: pendingbot; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.tools TO authenticated;
GRANT SELECT ON TABLE pendingbot.tools TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.tools TO service_role;


--
-- Name: TABLE user_contacts; Type: ACL; Schema: pendingbot; Owner: postgres
--

GRANT SELECT ON TABLE pendingbot.user_contacts TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.user_contacts TO authenticated;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.user_contacts TO service_role;


--
-- Name: TABLE user_handles; Type: ACL; Schema: pendingbot; Owner: postgres
--

GRANT SELECT ON TABLE pendingbot.user_handles TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.user_handles TO authenticated;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.user_handles TO service_role;


--
-- Name: TABLE user_quota; Type: ACL; Schema: pendingbot; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.user_quota TO authenticated;
GRANT SELECT ON TABLE pendingbot.user_quota TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.user_quota TO service_role;


--
-- Name: TABLE user_settings; Type: ACL; Schema: pendingbot; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.user_settings TO authenticated;
GRANT SELECT ON TABLE pendingbot.user_settings TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.user_settings TO service_role;


--
-- Name: TABLE user_unread_counts; Type: ACL; Schema: pendingbot; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.user_unread_counts TO authenticated;
GRANT SELECT ON TABLE pendingbot.user_unread_counts TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.user_unread_counts TO service_role;


--
-- Name: TABLE users; Type: ACL; Schema: pendingbot; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.users TO authenticated;
GRANT SELECT ON TABLE pendingbot.users TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.users TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: pendingbot; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA pendingbot GRANT SELECT ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA pendingbot GRANT SELECT,INSERT,DELETE,UPDATE ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA pendingbot GRANT SELECT,INSERT,DELETE,UPDATE ON TABLES TO service_role;


--


-- ──────────────────────────────────────────────────────────────────────
-- Cross-schema bits — pg_dump --schema=pendingbot can't capture these.
-- ──────────────────────────────────────────────────────────────────────

-- 1. Schema grants. service_role bypasses RLS but still needs schema USAGE
--    + table privileges; without these, PostgREST returns 42501.
GRANT USAGE ON SCHEMA pendingbot TO anon, authenticated, service_role;
GRANT ALL ON ALL TABLES IN SCHEMA pendingbot TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA pendingbot TO service_role;
GRANT ALL ON ALL ROUTINES IN SCHEMA pendingbot TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA pendingbot GRANT ALL ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA pendingbot GRANT ALL ON SEQUENCES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA pendingbot GRANT ALL ON ROUTINES TO service_role;

-- 2. New-user bootstrap. Fires after Supabase Auth creates a user row;
--    seeds the default bot conversations + participants for them.
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION pendingbot.bootstrap_new_user_trigger();

-- 3. Realtime publication. Only tables the clients subscribe to —
--    everything else stays out of the WAL stream Realtime watches.
ALTER PUBLICATION supabase_realtime ADD TABLE
  pendingbot.conversations,
  pendingbot.conversation_participants,
  pendingbot.messages,
  pendingbot.user_unread_counts,
  pendingbot.surf_runs,
  pendingbot.review_runs,
  pendingbot.bot_lookbacks;
