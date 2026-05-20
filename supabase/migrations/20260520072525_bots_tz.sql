-- Drop the experimental users.last_tz column added one migration ago —
-- the working design moves the timezone onto the *bot* (only public
-- bots actually need one; private bots are always 1:1 with their
-- creator and the per-turn clientTz already handles that path).
alter table pendingbot.users
  drop column if exists last_tz;

-- Public bots get an explicit IANA timezone for two purposes:
--   1) self-awareness — builder adds "你所在的时区是 X" to the system
--      prompt so the bot doesn't get confused about its own clock when
--      humans reference "tomorrow" / "this morning"
--   2) group time hints — group dispatch has no single user-clientTz
--      to lean on (multiple humans, server-triggered turns), so it
--      renders the per-message time in the bot's own tz
--
-- Private bots leave it NULL. Their 1:1 turns already render the time
-- hint in the user's clientTz, and they never enter groups, so a
-- self-tz is redundant.
alter table pendingbot.bots
  add column if not exists tz text;

-- Backfill existing public bots to UTC. Preset bots (creator_id IS
-- NULL) stay at UTC by convention — that's the spec. User-created
-- public bots also default to UTC at backfill (we don't have their
-- creator's tz historically); they can edit it in bot settings. New
-- public bots created after this migration get the creator's clientTz
-- at create time.
update pendingbot.bots
  set tz = 'Etc/UTC'
where tz is null
  and visibility in ('public_open', 'public_invite');

comment on column pendingbot.bots.tz is
  'IANA timezone for the bot itself (e.g. "Asia/Shanghai" / "Etc/UTC"). Used by builder for system-prompt self-awareness and by group dispatch as the time-hint tz. NULL for private bots — they follow the owner''s clientTz on each request and never enter groups.';
