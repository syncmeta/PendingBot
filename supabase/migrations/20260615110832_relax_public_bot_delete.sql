-- 公有 bot 默认永久（不可删/改/转私有），但若除创建者外无人采用，允许创建者删除。
-- "无人采用" = user_bot_contacts 无他人行 且 无 bot_invites 行。
-- 只改 DELETE 策略；UPDATE 不可变规则（bots_guard_public_update 触发器，仅 UPDATE 触发）不动。
drop policy if exists bots_creator_delete on pendingbot.bots;
create policy bots_creator_delete on pendingbot.bots for delete
  using (
    creator_id = auth.uid()
    and (
      visibility = 'private'
      or (
        not exists (
          select 1 from pendingbot.user_bot_contacts c
          where c.bot_id = bots.id and c.user_id <> bots.creator_id
        )
        and not exists (
          select 1 from pendingbot.bot_invites bi where bi.bot_id = bots.id
        )
      )
    )
  );
