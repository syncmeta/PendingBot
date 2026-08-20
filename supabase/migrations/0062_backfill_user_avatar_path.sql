-- Backfill `pendingbot.users.avatar_path` from
-- `custom_fields->>'avatar_attachment_id'` and drop the legacy key.
--
-- ProfileBootstrapView used to write the picked avatar attachment id
-- only into `custom_fields.avatar_attachment_id`, leaving the canonical
-- `avatar_path` column NULL. The contacts worker (and friend-request
-- preview) reads `avatar_path`, so peers always saw NULL → iOS fell
-- back to the deterministic BotAvatar placeholder. Both viewers of the
-- same peer rendered the same placeholder, surfacing as "对方的头像
-- 不对 — 但两个账号显示的是同一个".
--
-- iOS in this same change writes to `avatar_path` directly going
-- forward, so the legacy custom_fields key is dead weight after this
-- backfill. Strip it.
update pendingbot.users
   set avatar_path = nullif(custom_fields->>'avatar_attachment_id', ''),
       custom_fields = custom_fields - 'avatar_attachment_id'
 where avatar_path is null
   and custom_fields ? 'avatar_attachment_id';

-- Tidy up rows where avatar_path was already set (somehow) — strip the
-- duplicate custom_fields key so the column stops being authoritative.
update pendingbot.users
   set custom_fields = custom_fields - 'avatar_attachment_id'
 where custom_fields ? 'avatar_attachment_id';
