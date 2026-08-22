-- 补上一条迁移(20260822132304)漏掉的那一类会话:**用户回过话的**。
--
-- 上一版把「会话里只要有一条纪元窗口外的消息就整条跳过」当成安全网,那是从
-- 0025 / 20260520102713 抄来的套路 —— 但那两处防的是**整段替换会话内容**,
-- 而这里只是给预置消息重盖时间戳,真实消息一根汗毛都不碰。代价是线上有一个
-- 用户在 lorem 那条预设会话里回过一句,那条会话的 8 条预置消息就永远停在老
-- 基准上,同一个人的另外两条却挪走了 —— 屏幕上读出来两个不同的日期。
--
-- 新判据落在**单条消息**上:窗口内的重盖戳,窗口外的原样不动。会话的排序键
-- (user_unread_counts.last_message_at)只在它自己还指着窗口内的消息时才动 ——
-- 用户回过话的会话,排序键指着那条真实回复,不该被我们改。
--
-- 常量沿用上一条迁移的 preset_epoch_base_ts() / preset_epoch_window_end(),
-- 这里不再出现任何时间字面量。

BEGIN;

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
  -- 模板表:未来注册的用户从这里播种。被人手工挪出窗口的不碰。
  update pendingbot.preset_conversation_templates t
     set base_ts = pendingbot.preset_epoch_base_ts()
                     + (o.offset_seconds * interval '1 second'),
         updated_at = now()
    from pendingbot.preset_epoch_offsets() o
   where o.slug = t.slug
     and t.base_ts < win
     and t.base_ts is distinct from pendingbot.preset_epoch_base_ts()
                                     + (o.offset_seconds * interval '1 second');

  -- 已经播过种的会话。slug 优先取 metadata(20260523102129 之后建的会话才有);
  -- 老会话回落到 bot slug —— 私有预设 bot 会被克隆成 `<slug>-<uid>`,取第一段
  -- 就是原 slug。**不再按「用户回没回过话」整条排除。**
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
         and created_at < win          -- 只动预置的那些,真实消息不碰
       order by message_seq nulls last, created_at, id
    loop
      i := i + 1;
      update pendingbot.messages
         set created_at = slot + (i * interval '1 millisecond')
       where id = msg.id;
    end loop;

    -- 排序键只在它还指着预置消息时才跟着挪;指着真实回复的保持原样。
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

-- 自检:跑完之后,预设会话里不该再有任何落在基准分钟之外的预置消息 ——
-- 上一轮就是因为没有这条,「做完了」和「全做完了」长得一模一样。
DO $$
declare
  base timestamptz := pendingbot.preset_epoch_base_ts();
  win timestamptz := pendingbot.preset_epoch_window_end();
  bad int;
begin
  select count(*) into bad
    from pendingbot.messages m
    join pendingbot.conversations c on c.id = m.conversation_id
   where m.created_at < win
     and (m.created_at < base or m.created_at >= base + interval '1 minute')
     and exists (
           select 1 from pendingbot.preset_epoch_offsets() o
            where o.slug = coalesce(
                    c.metadata->>'preset_slug',
                    split_part((select b.slug from pendingbot.bots b where b.id = c.bot_id), '-', 1)
                  )
         );
  if bad > 0 then
    raise exception '% 条预置消息还停在基准分钟之外(老基准上的漏网之鱼)', bad;
  end if;
end $$;

COMMIT;
