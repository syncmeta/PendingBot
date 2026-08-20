-- 20260516073714_realtime_webhooks.sql
--
-- Fan-in for the Cloudflare-based realtime layer that replaces Supabase
-- Realtime. Each of the six tables the iOS client subscribes to gets an
-- AFTER INSERT/UPDATE/DELETE trigger that POSTs the row change to the
-- edge Worker via pg_net. The Worker (POST /v1/realtime-internal/notify)
-- resolves the row to a RealtimeHubDO topic and fans it out over
-- WebSocket to connected clients.
--
-- The payload shape mirrors a Supabase Database Webhook
-- ({ type, table, schema, record, old_record }) so the edge handler is
-- agnostic to how the webhook was wired.
--
-- Configuration: BOTH the destination URL and the shared secret come
-- from Supabase Vault, so nothing about a particular deployment is
-- baked into the migration ledger. Store them before pushing:
--   select vault.create_secret('https://<your-worker-host>/v1/realtime-internal/notify',
--                              'realtime_webhook_url');
--   select vault.create_secret('<value>', 'realtime_webhook_secret');
-- The Worker rejects any notify request whose X-Webhook-Secret header
-- doesn't match REALTIME_WEBHOOK_SECRET. With `realtime_webhook_url`
-- unset the trigger simply does nothing — that's the state a fresh
-- `supabase db reset` lands in, and it's the correct one.
--
-- DEPLOY ORDER — this migration MUST NOT be pushed before the edge
-- Worker carrying /v1/realtime-internal/notify is deployed, otherwise
-- every write fires a webhook into a 404. Push it as part of the
-- realtime cutover (worker deploy + secret set + this migration).

create extension if not exists pg_net;

create or replace function pendingbot.notify_realtime()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_secret  text;
  v_url     text;
  v_payload jsonb;
begin
  select decrypted_secret into v_secret
  from vault.decrypted_secrets
  where name = 'realtime_webhook_secret'
  limit 1;

  -- Where to POST row changes. Read from Vault, exactly like the secret
  -- above, so the destination is per-deployment configuration rather than
  -- a literal in the migration ledger. Set it once with:
  --
  --   select vault.create_secret(
  --     'https://<your-worker-host>/v1/realtime-internal/notify',
  --     'realtime_webhook_url');
  --
  -- Unset => this trigger is a no-op. That is deliberate: a hard-coded
  -- default would make every fresh `supabase db reset` fire live traffic
  -- at whoever happens to own that hostname.
  select decrypted_secret into v_url
  from vault.decrypted_secrets
  where name = 'realtime_webhook_url'
  limit 1;

  if v_url is null or v_url = '' then
    return null;
  end if;

  v_payload := jsonb_build_object(
    'type',       tg_op,
    'table',      tg_table_name,
    'schema',     tg_table_schema,
    'record',     case when tg_op = 'DELETE' then null else to_jsonb(new) end,
    'old_record', case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else null end
  );

  perform net.http_post(
    url     := v_url,
    body    := v_payload,
    headers := jsonb_build_object(
      'Content-Type',    'application/json',
      'X-Webhook-Secret', coalesce(v_secret, '')
    ),
    timeout_milliseconds := 5000
  );

  return null;
end;
$$;

-- conv:* topics — routed by conversation_id.
create trigger realtime_notify
  after insert or update or delete on pendingbot.messages
  for each row execute function pendingbot.notify_realtime();

create trigger realtime_notify
  after insert or update or delete on pendingbot.bot_lookbacks
  for each row execute function pendingbot.notify_realtime();

create trigger realtime_notify
  after insert or update or delete on pendingbot.group_continue_requests
  for each row execute function pendingbot.notify_realtime();

create trigger realtime_notify
  after insert or update or delete on pendingbot.conversation_participants
  for each row execute function pendingbot.notify_realtime();

-- user:* topics — routed by user_id.
create trigger realtime_notify
  after insert or update or delete on pendingbot.user_unread_counts
  for each row execute function pendingbot.notify_realtime();

create trigger realtime_notify
  after insert or update or delete on pendingbot.scroll_runs
  for each row execute function pendingbot.notify_realtime();
