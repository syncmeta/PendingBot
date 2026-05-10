-- Allow authenticated users to SELECT attachments that are referenced
-- as someone's avatar (`pendingbot.users.avatar_path = attachments.id`).
--
-- Without this, /v1/uploads/:id (which uses user JWT + RLS to gate the
-- read) returns "not found or no access" for any avatar that isn't your
-- own, even though the attachment id is already shared via /v1/contacts
-- and the friend-request preview. iOS UserAvatar then falls back to the
-- deterministic `BotAvatar(seed: userId)` placeholder — visible to the
-- user as "对方的头像不对，但两个账号看到的是同一个错的头像" (because
-- the placeholder is keyed by userId so every viewer renders the same
-- one).
--
-- Other attachments (chat-uploaded images, etc.) keep their existing
-- gates: owner, or participant of the bound conversation.

drop policy attachments_self_read on pendingbot.attachments;

create policy attachments_self_read on pendingbot.attachments
  for select
  using (
    user_id = auth.uid()
    or (conversation_id is not null and pendingbot.is_participant(conversation_id))
    or exists (
      select 1 from pendingbot.users
       where avatar_path = attachments.id::text
    )
  );

-- Index so the EXISTS lookup above is O(log N) — only fires for avatar
-- attachments (chat attachments short-circuit on the conversation_id
-- clause), but make it cheap when it does.
create index if not exists users_avatar_path_idx
  on pendingbot.users (avatar_path)
  where avatar_path is not null;
