-- Comprehensive self-delete. Inventoried every FK to auth.users and
-- pendingbot.conversations / pendingbot.messages and either NULLs them
-- out (audit_log, invite_codes, the message self-refs) or deletes them
-- (messages, convs, user-owned skills) before dropping auth.users.
--
-- Walk:
--   FK targets auth.users without ON DELETE CASCADE
--     conversations.user_id      → delete (covered)
--     messages.user_id           → delete (covered, but break parent FK first)
--     audit_log.user_id          → set null
--     audit_log.conversation_id  → set null (FK to conversations, also no cascade)
--     skills.owner_id            → delete user-owned, leave platform (NULL) skills
--     invite_codes.created_by    → set null (admin / referral history; keep code)
--     invite_codes.used_by       → set null
--     bots.owner_id              → ignore (admin-only path, regular users don't own bots)
--   FK targets pendingbot.messages without ON DELETE CASCADE
--     messages.parent_message_id, replaces_message_id, replaced_by_message_id
--                              → set null on every row pointing at one of ours

create or replace function pendingbot.delete_self_account()
returns void
language plpgsql
security definer
set search_path = pendingbot, public, auth
as $$
declare
  uid uuid := auth.uid();
  my_conv_ids uuid[];
  my_message_ids uuid[];
begin
  if uid is null then
    raise exception 'auth required';
  end if;

  select coalesce(array_agg(id), '{}') into my_conv_ids
    from pendingbot.conversations where user_id = uid;
  select coalesce(array_agg(id), '{}') into my_message_ids
    from pendingbot.messages
   where user_id = uid or conversation_id = any(my_conv_ids);

  -- 1. Snip every self-FK pointing at one of our messages, in any
  --    direction. Doing this once up-front is simpler than threading
  --    delete order around the three columns.
  update pendingbot.messages
     set parent_message_id = null
   where parent_message_id = any(my_message_ids);
  update pendingbot.messages
     set replaces_message_id = null
   where replaces_message_id = any(my_message_ids);
  update pendingbot.messages
     set replaced_by_message_id = null
   where replaced_by_message_id = any(my_message_ids);

  -- 2. audit_log: keep the rows (token accounting / billing trail) but
  --    decouple them from the user + their convs so the FK cascade can
  --    proceed.
  update pendingbot.audit_log set conversation_id = null
   where conversation_id = any(my_conv_ids);
  update pendingbot.audit_log set user_id = null where user_id = uid;

  -- 3. invite_codes: keep historical record, decouple the user.
  update pendingbot.invite_codes set created_by = null where created_by = uid;
  update pendingbot.invite_codes set used_by = null where used_by = uid;

  -- 4. skills: platform builtins (owner_id IS NULL) survive; user-owned
  --    custom skills go away. skill_subscriptions cascades on user_id.
  delete from pendingbot.skills where owner_id = uid;

  -- 5. Now the actual user-owned data. Order matters: messages have a
  --    cascading FK from conversations(id), so deleting convs first
  --    will sweep their messages — but we still want to clear the
  --    user's messages in OTHER convs (e.g. group chats) explicitly.
  delete from pendingbot.messages where user_id = uid;
  delete from pendingbot.conversation_participants
   where participant_type = 'user' and participant_id = uid;
  delete from pendingbot.conversations where user_id = uid;

  -- 6. Drop the auth row last. Cascades user_unread_counts,
  --    user_handles, user_contacts (both directions), device_tokens,
  --    skill_subscriptions, ai_picks, portrait_conversations,
  --    bot_reflections, pendingbot.users, user_settings, user_quota,
  --    + anything else that has on-delete-cascade on auth.users(id).
  delete from auth.users where id = uid;
end $$;

grant execute on function pendingbot.delete_self_account() to authenticated;
