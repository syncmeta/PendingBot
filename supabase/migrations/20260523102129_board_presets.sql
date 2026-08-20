BEGIN;

CREATE TABLE IF NOT EXISTS pendingbot.preset_conversation_templates (
    slug text PRIMARY KEY,
    bot_slug text NOT NULL,
    title text NOT NULL,
    base_ts timestamp with time zone NOT NULL DEFAULT '1970-01-01 00:00:00+00',
    messages jsonb NOT NULL DEFAULT '[]'::jsonb,
    sort_order integer NOT NULL DEFAULT 100,
    enabled boolean NOT NULL DEFAULT true,
    updated_at timestamp with time zone NOT NULL DEFAULT now(),
    updated_by uuid,
    CONSTRAINT preset_conversation_templates_messages_array
      CHECK (jsonb_typeof(messages) = 'array')
);
ALTER TABLE pendingbot.preset_conversation_templates OWNER TO postgres;
ALTER TABLE pendingbot.preset_conversation_templates ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON TABLE pendingbot.preset_conversation_templates TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.preset_conversation_templates TO service_role;

CREATE TABLE IF NOT EXISTS pendingbot.preset_group_templates (
    slug text PRIMARY KEY,
    title text NOT NULL,
    bot_slugs text[] NOT NULL DEFAULT '{}'::text[],
    join_policy pendingbot.group_join_policy NOT NULL DEFAULT 'approval',
    messages jsonb NOT NULL DEFAULT '[]'::jsonb,
    sort_order integer NOT NULL DEFAULT 100,
    enabled boolean NOT NULL DEFAULT true,
    updated_at timestamp with time zone NOT NULL DEFAULT now(),
    updated_by uuid,
    CONSTRAINT preset_group_templates_messages_array
      CHECK (jsonb_typeof(messages) = 'array')
);
ALTER TABLE pendingbot.preset_group_templates OWNER TO postgres;
ALTER TABLE pendingbot.preset_group_templates ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON TABLE pendingbot.preset_group_templates TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.preset_group_templates TO service_role;

CREATE TABLE IF NOT EXISTS pendingbot.group_member_invitations (
    id uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    conversation_id uuid NOT NULL,
    inviter_id uuid NOT NULL,
    invitee_id uuid NOT NULL,
    status pendingbot.join_request_status DEFAULT 'pending' NOT NULL,
    billing_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
    invitee_participates boolean NOT NULL DEFAULT true,
    decided_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT group_member_invitations_pkey PRIMARY KEY (id),
    CONSTRAINT group_member_invitations_conv_fkey
      FOREIGN KEY (conversation_id) REFERENCES pendingbot.conversations(id)
      ON DELETE CASCADE,
    CONSTRAINT group_member_invitations_inviter_fkey
      FOREIGN KEY (inviter_id) REFERENCES auth.users(id)
      ON DELETE CASCADE,
    CONSTRAINT group_member_invitations_invitee_fkey
      FOREIGN KEY (invitee_id) REFERENCES auth.users(id)
      ON DELETE CASCADE
);
ALTER TABLE pendingbot.group_member_invitations OWNER TO postgres;
CREATE UNIQUE INDEX IF NOT EXISTS idx_group_member_invitations_one_pending
  ON pendingbot.group_member_invitations (conversation_id, invitee_id)
  WHERE status = 'pending';
ALTER TABLE pendingbot.group_member_invitations ENABLE ROW LEVEL SECURITY;
CREATE POLICY group_member_invitations_invitee_read
  ON pendingbot.group_member_invitations FOR SELECT
  USING (invitee_id = auth.uid());
CREATE POLICY group_member_invitations_admin_read
  ON pendingbot.group_member_invitations FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM pendingbot.conversation_participants cp
       WHERE cp.conversation_id = group_member_invitations.conversation_id
         AND cp.participant_type = 'user'
         AND cp.participant_id = auth.uid()
         AND cp.role IN ('owner', 'admin')
    )
  );
GRANT SELECT ON TABLE pendingbot.group_member_invitations TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.group_member_invitations TO service_role;

INSERT INTO pendingbot.preset_conversation_templates
  (slug, bot_slug, title, base_ts, sort_order, messages)
VALUES
  ('lorem', 'lorem', '大概介绍这个 App', '1970-01-01 05:00:00+00', 10, '[
    "这里的机器人会不断回头查证自己说的话 自我批评 避免误导你",
    "会给你进谏（写奏折）会主动去探索 寻觅对你有价值的信息",
    "如何使用？你可以把这个 App 理解为部分账号是机器人的微信 聊就完事了",
    "这里先大概说下特性 说多了你可能看不下去",
    "返回消息主页 其它会话里会进一步说明",
    "最后介绍一下 Claude Opus 用某宝商家的话来评价就是：小贵！但真好用！",
    "有什么想问的可以直接在这里发消息问这个机器人",
    "不过还是强烈建议你先看看其它介绍 因为 Opus 确实贵"
  ]'::jsonb),
  ('ipsum', 'ipsum', '公有私有机器人', '1970-01-01 04:00:00+00', 20, '[
    "在这个 App 里面，你可以有若干机器人好友和人类好友",
    "现在这几个预设机器人好友里既有私有的，也有公有的（我就是公有的）",
    "公有机器人的公开程度有两种：邀请制 公开可加",
    "前者只能和创建者邀请的用户聊 后者所有人都能聊",
    "**一定注意！公有的机器人可能和 App 里的其他人聊天，不要向它透露任何隐私或敏感信息！**",
    "但也请注意：别人**不会**直接看到你和公有机器人之间的聊天记录，只是它在和别人聊天的时候能记得你",
    "一般情况下问题不大，但是如果机器人被别人策反呢？现实世界中的朋友也可能会透露你不想公开的秘密",
    "那为什么要设置公开的机器人？因为好玩啊 就像你的微信好友里不可能只有你的家人一样",
    "你可以创建公开的机器人，别人可以加它好友",
    "谁用机器人就计谁的费用，你创建的只是一个机器人格 这个逻辑和市面上很多产品类似 比如 [Character.ai](http://Character.ai)",
    "公有机器人不属于任何人 创建者对它的权限仅限于更改公开程度 看不到它的好友和消息",
    "如果创建私有机器人，它只会和你聊天 私有机器人的逻辑就和 ChatGPT 差不多了"
  ]'::jsonb),
  ('sit', 'sit', '同一个机器人可以有多个会话/模型', '1970-01-01 03:00:00+00', 30, '[
    "这是和微信逻辑最不一样的地方",
    "一个机器人，可以一直开新对话，和ChatGPT一样",
    "也可以理解为 你能给机器人开无数个小号",
    "跟不同小号聊天在不同的对话里 但回应你的都是那个机器人",
    "另外 你可以随意更换机器人的模型 记忆保持不变 消息历史保持不变",
    "世界上几乎所有模型都能选 接入了 OpenRouter",
    "最后介绍当前的 Kimi 和其他几个前沿国产模型最不一样的是识图能力",
    "像 GLM Deepseek 主模型是看不了图片的 他们看图的模型效果没 Kimi 好"
  ]'::jsonb),
  ('amet', 'amet', '我能为你做些什么？', '1970-01-01 02:00:00+00', 40, '[
    "这是目前 AI 应用最常见的问候",
    "但我觉得这个问题不应该 AI 问人类 而应该 AI 自己去发现",
    "因为人类普遍不清楚 AI 到底能为自己做些什么",
    "这就是这个 App 的使命之一：发现 AI 能为你做些什么",
    "当然基本的助手功能也能应付 后续还会接入能运行代码的沙箱",
    "接入沙箱之后 你就可以把这些机器人当一个面前有电脑的朋友 让它帮你做手机上不太好做的事",
    "最后介绍一下当前会话的预设模型 GLM",
    "较低成本的中国开源模型 性价比较高 主打编程能力 但仍和 Opus 有一定差距",
    "Deepseek 恢复原价后 GLM 会更便宜"
  ]'::jsonb),
  ('dolor', 'dolor', 'Grok - 群', '1970-01-01 01:00:00+00', 50, '[
    "机器人在群里，把它当人就好",
    "不用@它，它在适当的时候会说话的",
    "机器人产生的费用由群成员分摊",
    "分摊方式在群设置里面调整"
  ]'::jsonb),
  ('adipiscing', 'adipiscing', 'Gemini 3.5 Flash - 打电话', '1970-01-01 00:30:00+00', 60, '[
    "可以和机器人打电话，单独打或者在群里打都可以",
    "如果在群里，可以直接拉机器人进群语音，把它当人就好了"
  ]'::jsonb)
ON CONFLICT (slug) DO NOTHING;

INSERT INTO pendingbot.preset_group_templates
  (slug, title, bot_slugs, join_policy, sort_order, messages)
VALUES
  ('grok-gemini-group', 'Grok 和 Gemini 群', ARRAY['dolor','adipiscing']::text[], 'approval', 10, '[
    {"bot_slug":"dolor","content":"这是一个预设群聊：你、Grok 和 Gemini 都在里面。"},
    {"bot_slug":"adipiscing","content":"可以直接像群聊一样发消息，不需要 @，机器人会在适合的时候接话。"},
    {"bot_slug":"dolor","content":"群里的机器人费用默认按人头分摊，群设置里可以改成部分人 A 或群主全包。"}
  ]'::jsonb)
ON CONFLICT (slug) DO NOTHING;

CREATE OR REPLACE FUNCTION pendingbot.seed_sample_dialogue(
  p_conv_id uuid,
  p_user_id uuid,
  p_bot_id uuid,
  p_slug text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public'
AS $$
declare
  tpl record;
  item jsonb;
  msg text;
  i int := 0;
begin
  if exists (select 1 from pendingbot.messages where conversation_id = p_conv_id) then
    return;
  end if;

  select * into tpl
    from pendingbot.preset_conversation_templates
   where slug = p_slug
     and enabled = true;
  if not found then
    return;
  end if;

  for item in select * from jsonb_array_elements(tpl.messages) loop
    i := i + 1;
    msg := case
      when jsonb_typeof(item) = 'string' then item #>> '{}'
      else item->>'content'
    end;
    if msg is null or btrim(msg) = '' then
      continue;
    end if;
    insert into pendingbot.messages
      (id, client_message_id, conversation_id, sender_bot_id, role, status, content, created_at)
    values
      (pendingbot.uuidv7(), pendingbot.uuidv7(), p_conv_id, p_bot_id, 'bot', 'done', msg,
       tpl.base_ts + (i * interval '1 second'));
  end loop;

  update pendingbot.user_unread_counts
     set unread_count = 0
   where conversation_id = p_conv_id
     and user_id = p_user_id;
end $$;
ALTER FUNCTION pendingbot.seed_sample_dialogue(uuid, uuid, uuid, text) OWNER TO postgres;

CREATE OR REPLACE FUNCTION pendingbot._resolve_preset_bot_for_user(
  p_slug text,
  p_uid uuid
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public'
AS $$
declare
  src record;
  target_bot_id uuid;
  clone_slug text;
begin
  select id, slug, display_name, model_id, output_mode, is_active, config, visibility
    into src
    from pendingbot.bots
   where slug = p_slug
     and is_active = true
     and creator_id is null;
  if not found then
    return null;
  end if;

  if src.visibility = 'private' then
    clone_slug := src.slug || '-' || p_uid::text;
    select id into target_bot_id from pendingbot.bots where slug = clone_slug;
    if target_bot_id is null then
      insert into pendingbot.bots
        (slug, display_name, model_id, output_mode, is_active, config, visibility, creator_id)
      values
        (clone_slug, src.display_name, src.model_id, src.output_mode,
         src.is_active, src.config, 'private', p_uid)
      returning id into target_bot_id;
    end if;
  else
    target_bot_id := src.id;
  end if;

  insert into pendingbot.user_bot_contacts (user_id, bot_id, added_via)
  values (p_uid, target_bot_id, 'bootstrap')
  on conflict (user_id, bot_id) do nothing;

  return target_bot_id;
end $$;
ALTER FUNCTION pendingbot._resolve_preset_bot_for_user(text, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot._resolve_preset_bot_for_user(text, uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION pendingbot._seed_preset_group_dialogue(
  p_conv_id uuid,
  p_user_id uuid,
  p_messages jsonb
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public'
AS $$
declare
  item jsonb;
  msg text;
  bot_slug text;
  bot_id uuid;
  i int := 0;
  base_ts timestamptz := '1970-01-01 00:10:00+00'::timestamptz;
begin
  for item in select * from jsonb_array_elements(coalesce(p_messages, '[]'::jsonb)) loop
    i := i + 1;
    msg := item->>'content';
    bot_slug := item->>'bot_slug';
    if msg is null or btrim(msg) = '' then
      continue;
    end if;
    bot_id := pendingbot._resolve_preset_bot_for_user(bot_slug, p_user_id);
    if bot_id is null then
      continue;
    end if;
    insert into pendingbot.messages
      (id, client_message_id, conversation_id, sender_bot_id, role, status, content, created_at)
    values
      (pendingbot.uuidv7(), pendingbot.uuidv7(), p_conv_id, bot_id, 'bot', 'done', msg,
       base_ts + (i * interval '1 second'));
  end loop;

  update pendingbot.user_unread_counts
     set unread_count = 0
   where conversation_id = p_conv_id
     and user_id = p_user_id;
end $$;
ALTER FUNCTION pendingbot._seed_preset_group_dialogue(uuid, uuid, jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot._seed_preset_group_dialogue(uuid, uuid, jsonb) FROM PUBLIC;

CREATE OR REPLACE FUNCTION pendingbot.bootstrap_user_id(
  p_uid uuid,
  p_email text,
  p_meta jsonb
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public'
AS $$
declare
  tpl record;
  group_tpl record;
  conv_id uuid;
  target_bot_id uuid;
  member_bot_ids uuid[] := '{}';
  slug text;
  bot_id uuid;
begin
  insert into pendingbot.users (id, email, display_name)
  values (
    p_uid,
    p_email,
    coalesce(p_meta->>'name', p_meta->>'full_name', '你')
  )
  on conflict (id) do nothing;

  perform pendingbot.ensure_preset_handle(p_uid);

  for tpl in
    select *
      from pendingbot.preset_conversation_templates
     where enabled = true
     order by sort_order, slug
  loop
    target_bot_id := pendingbot._resolve_preset_bot_for_user(tpl.bot_slug, p_uid);
    if target_bot_id is null then
      continue;
    end if;

    if exists (
      select 1 from pendingbot.conversations
       where user_id = p_uid
         and bot_id = target_bot_id
         and conversation_type = 'user_bot'
    ) then
      continue;
    end if;

    insert into pendingbot.conversations
      (conversation_type, feature, user_id, bot_id, title, metadata)
    values
      ('user_bot', 'message', p_uid, target_bot_id, tpl.title,
       jsonb_build_object('source', 'preset_conversation', 'preset_slug', tpl.slug))
    returning id into conv_id;

    insert into pendingbot.conversation_participants
      (conversation_id, participant_type, participant_id, role)
    values
      (conv_id, 'user', p_uid, 'owner'),
      (conv_id, 'bot',  target_bot_id, 'member');

    perform pendingbot.seed_sample_dialogue(conv_id, p_uid, target_bot_id, tpl.slug);
  end loop;

  for group_tpl in
    select *
      from pendingbot.preset_group_templates
     where enabled = true
     order by sort_order, slug
  loop
    if exists (
      select 1 from pendingbot.conversations c
       where c.user_id = p_uid
         and c.conversation_type = 'group'
         and c.metadata->>'source' = 'preset_group'
         and c.metadata->>'preset_slug' = group_tpl.slug
    ) then
      continue;
    end if;

    member_bot_ids := '{}';
    foreach slug in array group_tpl.bot_slugs loop
      bot_id := pendingbot._resolve_preset_bot_for_user(slug, p_uid);
      if bot_id is not null then
        member_bot_ids := array_append(member_bot_ids, bot_id);
      end if;
    end loop;

    insert into pendingbot.conversations
      (conversation_type, feature, user_id, bot_id, title, metadata)
    values
      ('group', 'message', p_uid, null, group_tpl.title,
       jsonb_build_object('source', 'preset_group', 'preset_slug', group_tpl.slug))
    returning id into conv_id;

    insert into pendingbot.conversation_group_meta
      (conversation_id, title, join_policy, created_by)
    values
      (conv_id, group_tpl.title, group_tpl.join_policy, p_uid);

    insert into pendingbot.group_billing_config
      (conversation_id, mode, window_seconds, updated_by)
    values
      (conv_id, 'per_head', 86400, p_uid);

    insert into pendingbot.conversation_participants
      (conversation_id, participant_type, participant_id, role)
    values
      (conv_id, 'user', p_uid, 'owner');

    insert into pendingbot.group_member_billing (conversation_id, user_id)
    values (conv_id, p_uid)
    on conflict do nothing;

    foreach bot_id in array member_bot_ids loop
      insert into pendingbot.conversation_participants
        (conversation_id, participant_type, participant_id, role)
      values
        (conv_id, 'bot', bot_id, 'member')
      on conflict do nothing;
    end loop;

    perform pendingbot._seed_preset_group_dialogue(conv_id, p_uid, group_tpl.messages);
  end loop;

  perform pendingbot.ensure_self_conv(p_uid);
  perform pendingbot.seed_example_letter(p_uid);
end $$;
ALTER FUNCTION pendingbot.bootstrap_user_id(uuid, text, jsonb) OWNER TO postgres;

COMMIT;
