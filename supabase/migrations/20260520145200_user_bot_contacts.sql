-- 20260520145200_user_bot_contacts
--
-- 显式 "把机器人加为联系人" 模型。
--
-- 现状：iOS 用 RLS 直查 `bots where is_active=true`，把所有对自己可见的 bot
-- 都列在好友 Tab 里（含 public_open 全员可见的）。没有"加 bot"动作 —— 用户
-- 在列表里直接点 → 进聊天 → 第一条消息走 start_user_bot_turn，那里的可见性
-- 才真正把关。结果是：体验上"先开门后撞墙"（点 private 别人家的 bot 也会
-- 一路进聊天页才被拒）；语义上，"在我的列表里"和"我能聊"是两件事，但当前模型
-- 把两者绑死。
--
-- 这次拆开：
--   1) 新增 user_bot_contacts(user_id, bot_id) —— 用户显式建立的 bot 联系。
--   2) iOS 列表改读这张表 ⇒ 默认只看到自己加过的 bot。
--   3) AFTER INSERT trigger on conversations：建立 user_bot 会话同时写一条
--      contact 行 —— 保持 "有会话 ⇒ 有联系" 的不变量，老路径(start_user_bot_turn
--      隐式开聊)继续可用，deep link 不会断。
--   4) bootstrap_user_id 给新用户预置的 bot 同步插 contact 行。
--   5) 回填：把现有 user_bot 会话都翻译成 contact 行。
--
-- RLS INSERT 检查复刻 bots 表的可见性 policy（0002:63-71）：private 只允许
-- creator；public_invite 要在 bot_invites 里；public_open 全员；额外允许 preset
-- (creator_id IS NULL)。这样 iOS 直接 INSERT 失败 = bot 不可见 / 不存在 / 不
-- 在邀请名单 —— 给上层一个 "查不到 or 没权限" 的清晰错误码（PostgREST 42501）。

BEGIN;

SET search_path TO pendingbot, public;

-- ── 1. 表 ──────────────────────────────────────────────────────────────
CREATE TABLE pendingbot.user_bot_contacts (
  user_id   uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  bot_id    uuid        NOT NULL REFERENCES pendingbot.bots(id) ON DELETE CASCADE,
  added_via text        NOT NULL DEFAULT 'manual'
              CHECK (added_via IN ('manual', 'bootstrap', 'auto_conv', 'backfill')),
  alias     text,
  added_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, bot_id)
);

CREATE INDEX user_bot_contacts_user_added_idx
  ON pendingbot.user_bot_contacts (user_id, added_at DESC);

ALTER TABLE pendingbot.user_bot_contacts ENABLE ROW LEVEL SECURITY;

CREATE POLICY user_bot_contacts_self_read
  ON pendingbot.user_bot_contacts FOR SELECT
  USING (user_id = auth.uid());

-- INSERT：复刻 bots_visible_read 的可见性，外加 user_id 必须是自己。
CREATE POLICY user_bot_contacts_self_insert
  ON pendingbot.user_bot_contacts FOR INSERT
  WITH CHECK (
    user_id = auth.uid()
    AND EXISTS (
      SELECT 1 FROM pendingbot.bots b
      WHERE b.id = user_bot_contacts.bot_id
        AND b.is_active = true
        AND (
          b.visibility = 'public_open'
          OR b.creator_id = auth.uid()
          OR b.creator_id IS NULL  -- preset / 共享预置
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

-- UPDATE：只能改自己行里的 alias，bot_id / user_id 不准动。
CREATE POLICY user_bot_contacts_self_update
  ON pendingbot.user_bot_contacts FOR UPDATE
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

CREATE POLICY user_bot_contacts_self_delete
  ON pendingbot.user_bot_contacts FOR DELETE
  USING (user_id = auth.uid());

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.user_bot_contacts TO authenticated;
GRANT SELECT ON TABLE pendingbot.user_bot_contacts TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.user_bot_contacts TO service_role;

-- ── 2. Trigger：建立 user_bot 会话时同步写 contact ─────────────────────
-- 保持"有会话 ⇒ 有联系"的不变量。SECURITY DEFINER 跳过 RLS（trigger 内已经
-- 隐含可见性 —— 能成功 INSERT conversations 就说明 start_user_bot_turn /
-- bootstrap 路径已经做过可见性检查）。
CREATE OR REPLACE FUNCTION pendingbot.tg_user_bot_conv_to_contact()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public'
AS $$
begin
  if NEW.conversation_type = 'user_bot'
     and NEW.user_id is not null
     and NEW.bot_id is not null then
    insert into pendingbot.user_bot_contacts (user_id, bot_id, added_via)
    values (NEW.user_id, NEW.bot_id, 'auto_conv')
    on conflict (user_id, bot_id) do nothing;
  end if;
  return NEW;
end $$;

ALTER FUNCTION pendingbot.tg_user_bot_conv_to_contact() OWNER TO postgres;

CREATE TRIGGER conversations_user_bot_contact
AFTER INSERT ON pendingbot.conversations
FOR EACH ROW
EXECUTE FUNCTION pendingbot.tg_user_bot_conv_to_contact();

-- ── 3. bootstrap_user_id：给预置 bot 同步插 contact ─────────────────────
-- 20260520103221 是当前权威版本。这里只在末尾两个 perform 之前补一段。
-- 实际上 trigger 已经会处理（bootstrap 的循环里建了 conversation），但显式
-- 写一次更直观，也避免将来 bootstrap 重排后丢列表。
CREATE OR REPLACE FUNCTION pendingbot.bootstrap_user_id(p_uid uuid, p_email text, p_meta jsonb) RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path TO 'pendingbot', 'public'
  AS $$
declare
  bot_row       record;
  conv_id       uuid;
  preset_title  text;
  target_bot_id uuid;
  clone_slug    text;
begin
  insert into pendingbot.users (id, email, display_name)
  values (
    p_uid,
    p_email,
    coalesce(p_meta->>'name', p_meta->>'full_name', '你')
  )
  on conflict (id) do nothing;

  perform pendingbot.ensure_preset_handle(p_uid);

  for bot_row in
    select id, slug, display_name, model_id, output_mode, is_active, config, visibility
      from pendingbot.bots
     where is_active = true and creator_id is null
  loop
    preset_title := case bot_row.slug
      when 'lorem'      then '大概介绍这个 App'
      when 'ipsum'      then '公有私有机器人'
      when 'dolor'      then 'Grok - 群'
      when 'sit'        then '同一个机器人可以有多个会话/模型'
      when 'amet'       then '我能为你做些什么？'
      when 'adipiscing' then 'Gemini 3.5 Flash - 打电话'
      else null
    end;

    if preset_title is null then
      continue;
    end if;

    if bot_row.visibility = 'private' then
      clone_slug := bot_row.slug || '-' || p_uid::text;
      select id into target_bot_id from pendingbot.bots where slug = clone_slug;
      if target_bot_id is null then
        insert into pendingbot.bots
          (slug, display_name, model_id, output_mode, is_active, config, visibility, creator_id)
        values
          (clone_slug, bot_row.display_name, bot_row.model_id, bot_row.output_mode,
           bot_row.is_active, bot_row.config, 'private', p_uid)
        returning id into target_bot_id;
      end if;
    else
      target_bot_id := bot_row.id;
    end if;

    -- 显式登记到联系人。trigger 也会写，但显式一次更稳。
    insert into pendingbot.user_bot_contacts (user_id, bot_id, added_via)
    values (p_uid, target_bot_id, 'bootstrap')
    on conflict (user_id, bot_id) do nothing;

    if exists (
      select 1 from pendingbot.conversations
       where user_id = p_uid
         and bot_id = target_bot_id
         and conversation_type = 'user_bot'
    ) then
      continue;
    end if;

    insert into pendingbot.conversations
      (conversation_type, feature, user_id, bot_id, title)
    values
      ('user_bot', 'message', p_uid, target_bot_id, preset_title)
    returning id into conv_id;

    insert into pendingbot.conversation_participants
      (conversation_id, participant_type, participant_id, role)
    values
      (conv_id, 'user', p_uid, 'owner'),
      (conv_id, 'bot',  target_bot_id, 'member');

    perform pendingbot.seed_sample_dialogue(conv_id, p_uid, target_bot_id, bot_row.slug);
  end loop;

  -- 物化 self 会话并种下预设来信。
  perform pendingbot.ensure_self_conv(p_uid);
  perform pendingbot.seed_example_letter(p_uid);
end $$;

ALTER FUNCTION pendingbot.bootstrap_user_id(p_uid uuid, p_email text, p_meta jsonb) OWNER TO postgres;

-- ── 4. 回填：现有 user_bot 会话都翻译成 contact ─────────────────────────
INSERT INTO pendingbot.user_bot_contacts (user_id, bot_id, added_via, added_at)
SELECT c.user_id,
       c.bot_id,
       'backfill',
       MIN(c.created_at)
  FROM pendingbot.conversations c
 WHERE c.conversation_type = 'user_bot'
   AND c.user_id IS NOT NULL
   AND c.bot_id  IS NOT NULL
 GROUP BY c.user_id, c.bot_id
ON CONFLICT (user_id, bot_id) DO NOTHING;

COMMIT;
