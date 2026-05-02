-- 1. Capitalize preset bot display names so each starts with an uppercase
--    letter (Ipsum / Dolor / Sit / Amet / Consectetur / Adipiscing / Elit).
--    Lorem was already correct.
-- 2. Sync any existing user_bot conversation titles to the new names.
-- 3. Delete every conversation tied to the now-deactivated v1 preset bots
--    (xiaolu / lao-zhou / arong / jian) — both with and without messages.
--    `on delete cascade` on messages takes care of the message rows.

update pendingbot.bots set display_name = 'Ipsum'       where slug = 'ipsum';
update pendingbot.bots set display_name = 'Dolor'       where slug = 'dolor';
update pendingbot.bots set display_name = 'Sit'         where slug = 'sit';
update pendingbot.bots set display_name = 'Amet'        where slug = 'amet';
update pendingbot.bots set display_name = 'Consectetur' where slug = 'consectetur';
update pendingbot.bots set display_name = 'Adipiscing'  where slug = 'adipiscing';
update pendingbot.bots set display_name = 'Elit'        where slug = 'elit';

update pendingbot.conversations c
   set title = b.display_name
  from pendingbot.bots b
 where c.bot_id = b.id
   and c.conversation_type = 'user_bot'
   and b.slug in ('lorem','ipsum','dolor','sit','amet','consectetur','adipiscing','elit');

-- audit_log keeps a foreign-key reference to conversations; null it out
-- for the conversations we're about to delete so the cascade is clean.
update pendingbot.audit_log a
   set conversation_id = null
  from pendingbot.conversations c
  join pendingbot.bots b on b.id = c.bot_id
 where a.conversation_id = c.id
   and b.slug in ('xiaolu','lao-zhou','arong','jian');

delete from pendingbot.conversations c
 using pendingbot.bots b
 where c.bot_id = b.id
   and b.slug in ('xiaolu','lao-zhou','arong','jian');
