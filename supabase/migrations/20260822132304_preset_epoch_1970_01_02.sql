-- 预设(onboarding)会话的消息时间:1970-01-01 各占一个整点 → 1970-01-02 12:34。
--
-- 这批时间戳是**刻意**的标记(会话列表那格显示字面的「1970年」而不是「55 年
-- 前」),不是过期数据。这条迁移做三件事:
--
--   1. 把「基准戳」和「预置窗口」收成两个常量函数 —— 之前这两个字面量散在
--      迁移、判据、客户端三处,改一次要改三处,这次就是这么被发现的。
--      客户端那一份在 apps/pendingbot/Sources/Components/PresetEpoch.swift,
--      两边注释互指。
--   2. 把判据从 `created_at < '1970-01-02'` 换成 `< preset_epoch_window_end()`
--      (1971-01-01)。原判据的边界正好落在新基准戳**下面**,不换的话预置消息
--      会被当成"用户后来的真实回复",整条修复路径反过来。窗口取整年,以后基准
--      戳在 1970 年内怎么挪都不会再翻。
--   3. 给已经播过种、且用户还没回过话的会话重新盖戳(幂等)。
--
-- 排序:会话列表按 user_unread_counts.last_message_at 排(客户端取秒),所以
-- 五+一个预设会话不能撞在同一秒 —— 各 slug 在 12:34 这一分钟内错开秒,相对
-- 次序沿用原来那套整点。会话内部的消息改成错开**毫秒**:排序本来就走
-- message_seq,毫秒能保证一条会话的最后一条消息仍落在自己那一秒里,以后往模板
-- 里加几句话也不会顶到下一个 slug 的槽位上。

BEGIN;

-- ── 1. 常量 ─────────────────────────────────────────────────────────────

-- 预设消息的基准戳。1970-01-02 12:34(北京时间)= 04:34 UTC —— 产品要的是
-- UTC+8 屏幕上读出来的那个 12:34。要挪时间:改这里 + 改 PresetEpoch.base。
CREATE OR REPLACE FUNCTION pendingbot.preset_epoch_base_ts()
RETURNS timestamptz
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT '1970-01-02 04:34:00+00'::timestamptz $$;
ALTER FUNCTION pendingbot.preset_epoch_base_ts() OWNER TO postgres;

-- 预置窗口的右边界。落在窗口内 = 播种出来的;真实消息一律在窗口之外。
CREATE OR REPLACE FUNCTION pendingbot.preset_epoch_window_end()
RETURNS timestamptz
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT '1971-01-01 00:00:00+00'::timestamptz $$;
ALTER FUNCTION pendingbot.preset_epoch_window_end() OWNER TO postgres;

-- 每个预设会话在这一分钟里占的秒。次序 = 原来那套整点的次序
-- (lorem 05:00 → 最靠后 = 列表最上面 … 预设群 00:10 → 最靠前)。
CREATE OR REPLACE FUNCTION pendingbot.preset_epoch_offsets()
RETURNS TABLE (slug text, offset_seconds int)
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
  SELECT t.slug::text, t.offset_seconds::int
    FROM (VALUES
      ('lorem', 50),
      ('ipsum', 40),
      ('sit', 30),
      ('amet', 20),
      ('dolor', 10),
      ('adipiscing', 5),
      ('grok-gemini-group', 2)
    ) as t(slug, offset_seconds)
$$;
ALTER FUNCTION pendingbot.preset_epoch_offsets() OWNER TO postgres;

-- ── 2. 播种路径 ─────────────────────────────────────────────────────────

-- 与 20260523102129 的版本只差一处:会话内消息由错开「秒」改成错开「毫秒」,
-- 这样一条会话再长也留在自己那一秒的槽位里。
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
       tpl.base_ts + (i * interval '1 millisecond'));
  end loop;

  update pendingbot.user_unread_counts
     set unread_count = 0
   where conversation_id = p_conv_id
     and user_id = p_user_id;
end $$;
ALTER FUNCTION pendingbot.seed_sample_dialogue(uuid, uuid, uuid, text) OWNER TO postgres;

-- 预设群:基准戳从常量 + 本群 slug 的槽位算,不再自带一个 1970-01-01 字面量。
-- slug 从会话 metadata 取(bootstrap 建群时写的),取不到就落到最靠前的槽位。
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
  group_slug text;
  base_ts timestamptz;
begin
  select c.metadata->>'preset_slug' into group_slug
    from pendingbot.conversations c
   where c.id = p_conv_id;

  select pendingbot.preset_epoch_base_ts() + (o.offset_seconds * interval '1 second')
    into base_ts
    from pendingbot.preset_epoch_offsets() o
   where o.slug = group_slug;
  if base_ts is null then
    base_ts := pendingbot.preset_epoch_base_ts();
  end if;

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
       base_ts + (i * interval '1 millisecond'));
  end loop;

  update pendingbot.user_unread_counts
     set unread_count = 0
   where conversation_id = p_conv_id
     and user_id = p_user_id;
end $$;
ALTER FUNCTION pendingbot._seed_preset_group_dialogue(uuid, uuid, jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot._seed_preset_group_dialogue(uuid, uuid, jsonb) FROM PUBLIC;

-- 新建模板(board 里加的)默认落在基准戳上,而不是 1970-01-01 00:00。
ALTER TABLE pendingbot.preset_conversation_templates
  ALTER COLUMN base_ts SET DEFAULT pendingbot.preset_epoch_base_ts();

-- ── 3. 重新盖戳(幂等) ───────────────────────────────────────────────────

-- 把模板表和已经播过种的会话挪到当前常量上。再挪一次基准戳时:改常量函数,
-- 然后在新迁移里再调一次这个函数就行,不用重写一遍修复逻辑。
--
-- 只动"还停在预置窗口里、且用户没回过话"的会话 —— 只要会话里有一条窗口外的
-- 消息(= 真人来过),整条会话原样不动。
CREATE OR REPLACE FUNCTION pendingbot.restamp_preset_epoch_conversations()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public'
AS $$
declare
  win timestamptz := pendingbot.preset_epoch_window_end();
  conv record;
  msg record;
  slot timestamptz;
  i int;
  touched int := 0;
begin
  -- 3a. 模板表:未来注册的用户从这里播种。被人手工挪出窗口的不碰。
  update pendingbot.preset_conversation_templates t
     set base_ts = pendingbot.preset_epoch_base_ts()
                     + (o.offset_seconds * interval '1 second'),
         updated_at = now()
    from pendingbot.preset_epoch_offsets() o
   where o.slug = t.slug
     and t.base_ts < win
     and t.base_ts is distinct from pendingbot.preset_epoch_base_ts()
                                     + (o.offset_seconds * interval '1 second');

  -- 3b. 已经播过种的会话。slug 优先取 metadata(20260523102129 之后建的会话
  --     才有);老会话回落到 bot slug —— 私有预设 bot 会被克隆成
  --     `<slug>-<uid>`,取第一段就是原 slug。
  for conv in
    select c.id,
           coalesce(
             c.metadata->>'preset_slug',
             split_part(b.slug, '-', 1)
           ) as preset_slug
      from pendingbot.conversations c
      left join pendingbot.bots b on b.id = c.bot_id
     where exists (
             select 1 from pendingbot.messages m
              where m.conversation_id = c.id
                and m.created_at < win
           )
       and not exists (
             select 1 from pendingbot.messages m
              where m.conversation_id = c.id
                and m.created_at >= win
           )
  loop
    select pendingbot.preset_epoch_base_ts() + (o.offset_seconds * interval '1 second')
      into slot
      from pendingbot.preset_epoch_offsets() o
     where o.slug = conv.preset_slug;
    if slot is null then
      continue;   -- 不是我们认识的预设会话,别碰
    end if;

    i := 0;
    for msg in
      select id
        from pendingbot.messages
       where conversation_id = conv.id
       order by message_seq nulls last, created_at, id
    loop
      i := i + 1;
      update pendingbot.messages
         set created_at = slot + (i * interval '1 millisecond')
       where id = msg.id;
    end loop;

    -- 未读缓存里的 last_message_at 就是会话列表的排序键,跟着挪。
    update pendingbot.user_unread_counts
       set last_message_at = slot + (i * interval '1 millisecond')
     where conversation_id = conv.id
       and last_message_at < win;

    touched := touched + 1;
  end loop;

  return touched;
end $$;
ALTER FUNCTION pendingbot.restamp_preset_epoch_conversations() OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.restamp_preset_epoch_conversations() FROM PUBLIC;

SELECT pendingbot.restamp_preset_epoch_conversations();

-- ── 4. 自检 ─────────────────────────────────────────────────────────────
-- 干净库和已有库都要落到同一个结果,所以这几条不变式直接在迁移里断言,
-- 破了就整条回滚。
DO $$
declare
  base timestamptz := pendingbot.preset_epoch_base_ts();
  win timestamptz := pendingbot.preset_epoch_window_end();
  bad int;
begin
  -- 判据没反转:基准戳(和它那一分钟)必须还在预置窗口里面。
  if base >= win or base + interval '1 minute' > win then
    raise exception '基准戳 % 不在预置窗口 % 内,判据会把预置消息当成真实回复', base, win;
  end if;

  -- 模板都落在同一分钟里,且 base_ts 的倒序 = sort_order 的正序(= 会话列表次序)。
  select count(*) into bad
    from pendingbot.preset_conversation_templates t
    join pendingbot.preset_epoch_offsets() o on o.slug = t.slug
   where t.enabled
     and (t.base_ts < base or t.base_ts >= base + interval '1 minute');
  if bad > 0 then
    raise exception '% 条预设模板的 base_ts 不在基准分钟内', bad;
  end if;

  select count(*) into bad
    from (
      select t.slug,
             rank() over (order by t.base_ts desc) as by_ts,
             rank() over (order by t.sort_order, t.slug) as by_order
        from pendingbot.preset_conversation_templates t
       where t.enabled
    ) r
   where r.by_ts <> r.by_order;
  if bad > 0 then
    raise exception '% 条预设模板的时间次序和 sort_order 对不上,会话列表会乱序', bad;
  end if;

  -- 还没被真人回过话的预设会话,消息必须全部落在基准分钟里。
  select count(*) into bad
    from pendingbot.conversations c
   where exists (
           select 1 from pendingbot.messages m
            where m.conversation_id = c.id and m.created_at < win
         )
     and not exists (
           select 1 from pendingbot.messages m
            where m.conversation_id = c.id and m.created_at >= win
         )
     and exists (
           select 1 from pendingbot.preset_epoch_offsets() o
            where o.slug = coalesce(
                    c.metadata->>'preset_slug',
                    split_part((select b.slug from pendingbot.bots b where b.id = c.bot_id), '-', 1)
                  )
         )
     and exists (
           select 1 from pendingbot.messages m
            where m.conversation_id = c.id
              and (m.created_at < base or m.created_at >= base + interval '1 minute')
         );
  if bad > 0 then
    raise exception '% 条预设会话没被重新盖戳', bad;
  end if;
end $$;

COMMIT;
