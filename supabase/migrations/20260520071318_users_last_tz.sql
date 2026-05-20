-- Persist the client's last-known IANA timezone so group-dispatch (which
-- has no live request body to read clientTz from when triggered by a DO
-- alarm) can still render the per-turn time hint in the user's local
-- clock. 1:1 chats keep using the clientTz that arrives on each request
-- — this column is the fallback source for everything that runs
-- detached from the request.
alter table pendingbot.users
  add column if not exists last_tz text;

comment on column pendingbot.users.last_tz is
  'Last clientTz observed from this user''s requests (IANA name, e.g. "Asia/Shanghai"). Updated by edge on /v1/messages. Used by group-dispatch + any other detached path that needs to render a localized time hint without a live request.';
