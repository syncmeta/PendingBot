-- 0001_init — full PendingBot schema, namespaced under `pendingbot.*`.
--
-- Design references (consult before editing):
--   .claude/plans/pendingbot-rewrite/04-schema-and-sync.md
--   .claude/plans/pendingbot-rewrite/03-streaming-interrupt.md
--   .claude/plans/pendingbot-rewrite/01-architecture.md
--
-- Conventions enforced here:
--   - Schema namespace `pendingbot.*` (multi-product co-existence)
--   - Primary keys + client_message_id are UUID v7 (B-tree friendly write order)
--   - Time fields are timestamptz (not unix epoch int)
--   - JSON fields are jsonb (not text)
--   - Enums are text + CHECK (not PG enum types — easier to migrate)
--   - RLS strategy is "user must be in conversation_participants"
--     (handles user-bot, user-user, group, discuss uniformly)
--   - All "live" tables added to supabase_realtime publication
-- =============================================================================

create schema if not exists pendingbot;

-- ── UUID v7 helper (Postgres < 18 fallback) ─────────────────────────────────
-- Postgres 18+ ships uuidv7() in core; this function is a stand-in for older
-- engines. It generates RFC 9562 v7 UUIDs (48-bit ms timestamp + random).
-- Drop & re-create on every migration for idempotence (cheap).
create or replace function pendingbot.uuidv7()
returns uuid
language plpgsql
volatile
as $$
declare
  unix_ts_ms bigint;
  uuid_bytes bytea;
begin
  unix_ts_ms = (extract(epoch from clock_timestamp()) * 1000)::bigint;
  uuid_bytes = gen_random_bytes(16);
  -- Stamp timestamp into bytes 0..5
  uuid_bytes = set_byte(uuid_bytes, 0, ((unix_ts_ms >> 40) & 255)::int);
  uuid_bytes = set_byte(uuid_bytes, 1, ((unix_ts_ms >> 32) & 255)::int);
  uuid_bytes = set_byte(uuid_bytes, 2, ((unix_ts_ms >> 24) & 255)::int);
  uuid_bytes = set_byte(uuid_bytes, 3, ((unix_ts_ms >> 16) & 255)::int);
  uuid_bytes = set_byte(uuid_bytes, 4, ((unix_ts_ms >>  8) & 255)::int);
  uuid_bytes = set_byte(uuid_bytes, 5, ( unix_ts_ms        & 255)::int);
  -- Set version (7) in byte 6 (high nibble)
  uuid_bytes = set_byte(uuid_bytes, 6, (112 | (get_byte(uuid_bytes, 6) & 15))::int);
  -- Set variant (10xx) in byte 8 (high two bits)
  uuid_bytes = set_byte(uuid_bytes, 8, (128 | (get_byte(uuid_bytes, 8) & 63))::int);
  return encode(uuid_bytes, 'hex')::uuid;
end;
$$;

-- =============================================================================
-- USERS — mirror of auth.users with product-specific metadata.
-- =============================================================================

create table pendingbot.users (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '',
  email text,
  is_admin boolean not null default false,
  bio text default '',
  avatar_path text,
  custom_fields jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- =============================================================================
-- BOTS — registry of bot personas.
-- =============================================================================

create table pendingbot.bots (
  id uuid primary key default pendingbot.uuidv7(),
  slug text unique not null,
  display_name text not null,
  model_id text not null,
  -- Output mode is per-bot, fixed at create time, to keep prompt prefix stable
  -- (avoid cache-thrashing from runtime mode switches). 'bubble' = WeChat-style
  -- multi-bubble per turn; 'single' = one continuous reply per turn.
  output_mode text not null default 'single' check (output_mode in ('single', 'bubble')),
  is_active boolean not null default true,
  config jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- =============================================================================
-- CONVERSATIONS — supports user-bot, user-user, group, discuss uniformly.
-- =============================================================================

create table pendingbot.conversations (
  id uuid primary key default pendingbot.uuidv7(),
  conversation_type text not null default 'user_bot'
    check (conversation_type in ('user_bot', 'user_user', 'group', 'discuss', 'surf', 'portrait')),
  feature text not null default 'message'
    check (feature in ('message', 'discuss', 'surf', 'portrait')),
  -- Creator. user_user/group still record the originator.
  user_id uuid references auth.users(id),
  -- Bot pinned to this conv (NULL for user_user; NULLABLE for group with no
  -- default bot). For discuss with multiple bots, leave NULL and use
  -- conversation_participants to enumerate.
  bot_id uuid references pendingbot.bots(id),
  title text,
  round_count int not null default 0,
  last_turn_status text default null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_conversations_user_updated
  on pendingbot.conversations (user_id, updated_at desc)
  where user_id is not null;

-- =============================================================================
-- CONVERSATION_PARTICIPANTS — polymorphic membership (user OR bot).
-- =============================================================================

create table pendingbot.conversation_participants (
  conversation_id uuid not null references pendingbot.conversations(id) on delete cascade,
  participant_type text not null check (participant_type in ('user', 'bot')),
  participant_id uuid not null,
  role text not null default 'member'
    check (role in ('owner', 'admin', 'member', 'observer')),
  joined_at timestamptz not null default now(),
  last_read_message_id uuid,
  primary key (conversation_id, participant_type, participant_id)
);

create index idx_participants_user
  on pendingbot.conversation_participants (participant_id)
  where participant_type = 'user';

create index idx_participants_bot
  on pendingbot.conversation_participants (participant_id)
  where participant_type = 'bot';

-- =============================================================================
-- MESSAGES — single source of truth, edit via linked-list, log= system msgs.
-- =============================================================================

create table pendingbot.messages (
  id uuid primary key default pendingbot.uuidv7(),
  client_message_id uuid unique not null,
  conversation_id uuid not null references pendingbot.conversations(id) on delete cascade,
  -- For role='user'|'human': sender's auth.users.id
  -- For role='bot': null (bot identified via sender_bot_id)
  -- For role='log': null
  user_id uuid references auth.users(id),
  sender_bot_id uuid references pendingbot.bots(id),
  role text not null check (role in ('user', 'bot', 'human', 'log')),
  content text,
  -- Streaming partial state. While bot is streaming, we update
  -- content_partial; on finish, copy to content + null partial + status='done'.
  content_partial text,
  status text not null default 'pending'
    check (status in ('pending', 'streaming', 'done', 'interrupted', 'interrupted_partial', 'error', 'replaced', 'deleted')),
  stop_requested boolean not null default false,
  -- Edit history (linked list). Editing = INSERT new row + UPDATE old row's
  -- replaced_by. UI shows tail (status != 'replaced'); LLM context same.
  replaces_message_id uuid references pendingbot.messages(id),
  replaced_by_message_id uuid references pendingbot.messages(id),
  -- Bubble mode: same turn → multiple bot bubbles share group_id
  bubble_group_id uuid,
  -- The user message that triggered this bot reply (for branching / retries)
  parent_message_id uuid references pendingbot.messages(id),
  attachments jsonb,
  -- System messages (role='log'): structured payload. UI renders by log_kind.
  -- Examples: 'review:step', 'review:card', 'review:closing',
  --           'surf:step', 'surf:result', 'surf:thinking'
  log_kind text,
  log_payload jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_messages_conv_time
  on pendingbot.messages (conversation_id, created_at desc);

create index idx_messages_user_time
  on pendingbot.messages (user_id, created_at desc)
  where user_id is not null;

-- Full-text search (simple config; pg_jieba can replace later for Chinese)
alter table pendingbot.messages
  add column content_tsv tsvector
  generated always as (to_tsvector('simple', coalesce(content, ''))) stored;

create index idx_messages_search
  on pendingbot.messages
  using gin (content_tsv);

-- =============================================================================
-- ATTACHMENTS — R2 object metadata.
-- =============================================================================

create table pendingbot.attachments (
  id uuid primary key default pendingbot.uuidv7(),
  user_id uuid not null references auth.users(id),
  conversation_id uuid references pendingbot.conversations(id) on delete cascade,
  -- R2 object key (e.g. 'yyyy-mm/<uuid>.<ext>')
  r2_key text not null,
  thumb_r2_key text,                 -- thumbnail variant key (optional)
  mime_type text not null,
  byte_size int not null,
  width int,
  height int,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index idx_attachments_conv on pendingbot.attachments (conversation_id);

-- =============================================================================
-- USER_UNREAD_COUNTS — derived table for main-list badge UI.
-- Maintained by trigger on messages INSERT. Realtime-published so client's
-- top-level user channel can update list view in real time without
-- subscribing to messages directly.
-- =============================================================================

create table pendingbot.user_unread_counts (
  user_id uuid not null references auth.users(id) on delete cascade,
  conversation_id uuid not null references pendingbot.conversations(id) on delete cascade,
  unread_count int not null default 0,
  last_message_id uuid,
  last_message_at timestamptz,
  last_message_preview text,
  primary key (user_id, conversation_id)
);

create or replace function pendingbot.update_unread_counts()
returns trigger
language plpgsql
as $$
begin
  -- Don't run for log/system messages or replaced edits.
  if new.role = 'log' or new.status = 'replaced' then
    return new;
  end if;

  insert into pendingbot.user_unread_counts (
    user_id, conversation_id, unread_count,
    last_message_id, last_message_at, last_message_preview
  )
  select
    cp.participant_id,
    new.conversation_id,
    1,
    new.id,
    new.created_at,
    left(coalesce(new.content, ''), 100)
  from pendingbot.conversation_participants cp
  where cp.conversation_id = new.conversation_id
    and cp.participant_type = 'user'
    -- Skip the sender themselves
    and cp.participant_id is distinct from new.user_id
  on conflict (user_id, conversation_id) do update
    set unread_count = pendingbot.user_unread_counts.unread_count + 1,
        last_message_id = new.id,
        last_message_at = new.created_at,
        last_message_preview = left(coalesce(new.content, ''), 100);
  return new;
end;
$$;

create trigger messages_unread_after_insert
  after insert on pendingbot.messages
  for each row execute function pendingbot.update_unread_counts();

-- =============================================================================
-- AUDIT LOG — LLM call accounting (admin-only).
-- =============================================================================

create table pendingbot.audit_log (
  id uuid primary key default pendingbot.uuidv7(),
  user_id uuid references auth.users(id),
  conversation_id uuid references pendingbot.conversations(id),
  task_type text not null,
  model_id text not null,
  input_tokens int not null default 0,
  output_tokens int not null default 0,
  total_tokens int not null default 0,
  cache_read_tokens int not null default 0,
  cache_write_tokens int not null default 0,
  cost_usd numeric(12, 6),
  generation_id text,
  latency_ms int,
  tag text,                   -- e.g. 'admin_action' for admin writes
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index idx_audit_user_time on pendingbot.audit_log (user_id, created_at desc);
create index idx_audit_model_time on pendingbot.audit_log (model_id, created_at desc);

-- =============================================================================
-- MODEL_PRICING — looked up to compute audit cost in USD.
-- Refreshed by cron from OpenRouter's /api/v1/models.
-- =============================================================================

create table pendingbot.model_pricing (
  model_id text primary key,
  input_price numeric(12, 8) not null,            -- USD per 1M input tokens
  cached_input_price numeric(12, 8),              -- USD per 1M cache-read tokens
  output_price numeric(12, 8) not null,
  currency text not null default 'USD',
  updated_at timestamptz not null default now()
);

-- =============================================================================
-- SKILLS — Anthropic Claude Skills format. User-authored; can be public/forkable.
-- =============================================================================

create table pendingbot.skills (
  id uuid primary key default pendingbot.uuidv7(),
  owner_id uuid not null references auth.users(id),
  -- Anthropic format frontmatter: { name, description, allowed_tools[], version, ... }
  frontmatter jsonb not null,
  body_md text not null,
  visibility text not null default 'private' check (visibility in ('private', 'public')),
  forked_from uuid references pendingbot.skills(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_skills_owner on pendingbot.skills (owner_id);
create index idx_skills_public on pendingbot.skills (visibility) where visibility = 'public';

create table pendingbot.skill_subscriptions (
  user_id uuid not null references auth.users(id) on delete cascade,
  skill_id uuid not null references pendingbot.skills(id) on delete cascade,
  conversation_id uuid references pendingbot.conversations(id) on delete cascade,
  installed_at timestamptz not null default now(),
  primary key (user_id, skill_id, conversation_id)
);

-- =============================================================================
-- TOOLS — agent-callable functions (builtin / mcp / custom).
-- =============================================================================

create table pendingbot.tools (
  id uuid primary key default pendingbot.uuidv7(),
  owner_id uuid references auth.users(id),  -- NULL = platform builtin
  source_type text not null check (source_type in ('builtin', 'mcp', 'custom')),
  name text not null,
  description text,
  schema_json jsonb not null,    -- JSON schema for arguments
  config_json jsonb,             -- impl-specific (MCP server URL, etc.)
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

-- =============================================================================
-- BOT_REFLECTIONS — bot's structured self-knowledge (limit/grow/keep).
-- Output of the review process; feeds bot's system prompt alongside Honcho.
-- The two sources may contradict — by design (dialectic evolution).
-- =============================================================================

create table pendingbot.bot_reflections (
  id uuid primary key default pendingbot.uuidv7(),
  bot_id uuid not null references pendingbot.bots(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  review_run_id uuid,
  -- 'limit' = my limitations; 'grow' = traits to develop; 'keep' = traits to preserve
  kind text not null check (kind in ('limit', 'grow', 'keep')),
  content text not null,
  created_at timestamptz not null default now()
);

create index idx_reflections_bot_user_time
  on pendingbot.bot_reflections (bot_id, user_id, created_at desc);

-- =============================================================================
-- SURF_RUNS / REVIEW_RUNS — async task state (long-running LLM agent loops).
-- =============================================================================

create table pendingbot.surf_runs (
  id uuid primary key default pendingbot.uuidv7(),
  conversation_id uuid not null references pendingbot.conversations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending'
    check (status in ('pending', 'running', 'done', 'error', 'cancelled')),
  progress jsonb not null default '{}'::jsonb,
  cost_budget_usd numeric(10, 4),
  cost_used_usd numeric(10, 4) not null default 0,
  trigger text,                 -- 'auto' | 'user' | 'panel'
  started_at timestamptz,
  finished_at timestamptz,
  created_at timestamptz not null default now()
);

create index idx_surf_runs_conv on pendingbot.surf_runs (conversation_id);

create table pendingbot.review_runs (
  id uuid primary key default pendingbot.uuidv7(),
  -- Review is integrated into message conv now (no separate review conv id).
  conversation_id uuid not null references pendingbot.conversations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  bot_id uuid not null references pendingbot.bots(id),
  status text not null default 'pending'
    check (status in ('pending', 'running', 'done', 'error', 'cancelled')),
  trigger text,                 -- 'auto' | 'user' | 'panel'
  started_at timestamptz,
  finished_at timestamptz,
  created_at timestamptz not null default now()
);

create index idx_review_runs_conv on pendingbot.review_runs (conversation_id);

-- =============================================================================
-- INVITES — admin-issued invite codes (signup gating).
-- =============================================================================

create table pendingbot.invites (
  code text primary key,
  created_by uuid references auth.users(id),
  used_by uuid references auth.users(id),
  used_at timestamptz,
  expires_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- =============================================================================
-- USER_SETTINGS — per-user app preferences.
-- =============================================================================

create table pendingbot.user_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  theme text default 'system' check (theme in ('system', 'light', 'dark')),
  locale text,
  notifications_enabled boolean not null default true,
  custom_settings jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

-- =============================================================================
-- USER_QUOTA — per-user LLM spend caps.
-- =============================================================================

create table pendingbot.user_quota (
  user_id uuid primary key references auth.users(id) on delete cascade,
  daily_limit_usd numeric(10, 4) not null default 1.0,
  monthly_limit_usd numeric(10, 4) not null default 10.0,
  daily_used_usd numeric(10, 4) not null default 0,
  monthly_used_usd numeric(10, 4) not null default 0,
  reset_daily_at timestamptz,
  reset_monthly_at timestamptz,
  updated_at timestamptz not null default now()
);

-- =============================================================================
-- DEVICE_TOKENS — APNS / Web Push registration.
-- =============================================================================

create table pendingbot.device_tokens (
  id uuid primary key default pendingbot.uuidv7(),
  user_id uuid not null references auth.users(id) on delete cascade,
  platform text not null check (platform in ('ios', 'web', 'android')),
  token text not null,
  endpoint text,                -- web push endpoint URL
  metadata jsonb not null default '{}'::jsonb,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  unique (user_id, token)
);

-- =============================================================================
-- AI_PICKS — AI-curated bookmarks / favorites.
-- =============================================================================

create table pendingbot.ai_picks (
  id uuid primary key default pendingbot.uuidv7(),
  user_id uuid not null references auth.users(id) on delete cascade,
  source text,
  url text,
  title text,
  summary text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index idx_ai_picks_user_time on pendingbot.ai_picks (user_id, created_at desc);

-- =============================================================================
-- PORTRAITS — generated content (memos, schedules, alarms, bills, moments).
-- =============================================================================

create table pendingbot.portraits (
  id uuid primary key default pendingbot.uuidv7(),
  user_id uuid not null references auth.users(id) on delete cascade,
  conversation_id uuid references pendingbot.conversations(id) on delete cascade,
  kind text not null check (kind in ('memos', 'schedule', 'alarms', 'bills', 'moments', 'chat')),
  content jsonb not null,
  source_summary text,
  created_at timestamptz not null default now()
);

create index idx_portraits_user_kind_time
  on pendingbot.portraits (user_id, kind, created_at desc);

-- =============================================================================
-- DISCUSS_SETTINGS — per-bot config for the 议论 (discuss) feature.
-- (renamed from old debate_settings)
-- =============================================================================

create table pendingbot.discuss_settings (
  bot_id uuid primary key references pendingbot.bots(id) on delete cascade,
  enabled boolean not null default false,
  config jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

-- =============================================================================
-- REALTIME PUBLICATION — what gets pushed via Supabase Realtime.
-- =============================================================================

alter publication supabase_realtime add table pendingbot.messages;
alter publication supabase_realtime add table pendingbot.user_unread_counts;
alter publication supabase_realtime add table pendingbot.surf_runs;
alter publication supabase_realtime add table pendingbot.review_runs;
alter publication supabase_realtime add table pendingbot.conversations;
alter publication supabase_realtime add table pendingbot.conversation_participants;

-- =============================================================================
-- RLS — uniform "user is participant in conversation" rule for chat tables.
-- Admin tables (audit_log, invites, model_pricing, etc.) are service-role only.
-- =============================================================================

alter table pendingbot.users enable row level security;
alter table pendingbot.bots enable row level security;
alter table pendingbot.conversations enable row level security;
alter table pendingbot.conversation_participants enable row level security;
alter table pendingbot.messages enable row level security;
alter table pendingbot.attachments enable row level security;
alter table pendingbot.user_unread_counts enable row level security;
alter table pendingbot.skills enable row level security;
alter table pendingbot.skill_subscriptions enable row level security;
alter table pendingbot.tools enable row level security;
alter table pendingbot.surf_runs enable row level security;
alter table pendingbot.review_runs enable row level security;
alter table pendingbot.bot_reflections enable row level security;
alter table pendingbot.user_settings enable row level security;
alter table pendingbot.user_quota enable row level security;
alter table pendingbot.device_tokens enable row level security;
alter table pendingbot.ai_picks enable row level security;
alter table pendingbot.portraits enable row level security;
alter table pendingbot.discuss_settings enable row level security;
alter table pendingbot.audit_log enable row level security;
alter table pendingbot.model_pricing enable row level security;
alter table pendingbot.invites enable row level security;

-- ── Helper function: am I in the participants of this conversation? ─────────
create or replace function pendingbot.is_participant(conv_id uuid)
returns boolean
language sql
stable
security invoker
as $$
  select exists (
    select 1 from pendingbot.conversation_participants
    where conversation_id = conv_id
      and participant_type = 'user'
      and participant_id = auth.uid()
  );
$$;

-- ── users: only see/edit own row ───────────────────────────────────────────
create policy users_self_read on pendingbot.users
  for select using (id = auth.uid());
create policy users_self_update on pendingbot.users
  for update using (id = auth.uid());

-- ── bots: any logged-in user reads; only admin writes (via service role) ───
create policy bots_authenticated_read on pendingbot.bots
  for select using (auth.role() = 'authenticated');

-- ── conversations / messages / attachments: participant-gated ──────────────
create policy conversations_participant_read on pendingbot.conversations
  for select using (pendingbot.is_participant(id));
create policy conversations_owner_write on pendingbot.conversations
  for insert with check (user_id = auth.uid());
create policy conversations_owner_update on pendingbot.conversations
  for update using (user_id = auth.uid());

create policy participants_self_read on pendingbot.conversation_participants
  for select using (
    -- See your own row
    (participant_type = 'user' and participant_id = auth.uid())
    -- Or any row in a conv where you're a participant
    or pendingbot.is_participant(conversation_id)
  );

create policy messages_participant_read on pendingbot.messages
  for select using (pendingbot.is_participant(conversation_id));
create policy messages_participant_insert on pendingbot.messages
  for insert with check (
    pendingbot.is_participant(conversation_id)
    and (
      (role = 'user' and user_id = auth.uid())
      or (role = 'human' and user_id = auth.uid())
      or role = 'log'
      -- bot/log inserts come through service role (Worker) and bypass RLS
    )
  );
create policy messages_self_update on pendingbot.messages
  for update using (
    user_id = auth.uid() and role in ('user', 'human')
  );

create policy attachments_self_read on pendingbot.attachments
  for select using (
    user_id = auth.uid()
    or (conversation_id is not null and pendingbot.is_participant(conversation_id))
  );
create policy attachments_self_insert on pendingbot.attachments
  for insert with check (user_id = auth.uid());

-- ── user_unread_counts: only own rows ─────────────────────────────────────
create policy unread_self_read on pendingbot.user_unread_counts
  for select using (user_id = auth.uid());
create policy unread_self_update on pendingbot.user_unread_counts
  for update using (user_id = auth.uid());

-- ── skills: public + own ────────────────────────────────────────────────────
create policy skills_public_or_own_read on pendingbot.skills
  for select using (visibility = 'public' or owner_id = auth.uid());
create policy skills_own_write on pendingbot.skills
  for insert with check (owner_id = auth.uid());
create policy skills_own_update on pendingbot.skills
  for update using (owner_id = auth.uid());
create policy skills_own_delete on pendingbot.skills
  for delete using (owner_id = auth.uid());

create policy skill_subs_self on pendingbot.skill_subscriptions
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ── tools: builtin (owner_id null) visible to all; user tools visible to owner
create policy tools_visible on pendingbot.tools
  for select using (owner_id is null or owner_id = auth.uid());

-- ── surf/review runs: own only ─────────────────────────────────────────────
create policy surf_self on pendingbot.surf_runs
  for select using (user_id = auth.uid());
create policy review_self on pendingbot.review_runs
  for select using (user_id = auth.uid());

-- ── bot_reflections: NOT readable by client (server uses service role)
-- (no select policy = deny by default with RLS enabled)

-- ── user_settings / user_quota / device_tokens / ai_picks / portraits: own only
create policy settings_self on pendingbot.user_settings
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy quota_self_read on pendingbot.user_quota
  for select using (user_id = auth.uid());
create policy devices_self on pendingbot.device_tokens
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy picks_self on pendingbot.ai_picks
  for select using (user_id = auth.uid());
create policy portraits_self on pendingbot.portraits
  for select using (user_id = auth.uid());

-- ── audit_log / model_pricing / invites: NO policies = deny all client access
-- Worker uses service role for these.

-- =============================================================================
-- Helpful: grant usage on schema to authenticated + anon roles
-- =============================================================================
grant usage on schema pendingbot to authenticated, anon;
grant select, insert, update, delete on all tables in schema pendingbot to authenticated;
grant select on all tables in schema pendingbot to anon;
-- Future tables inherit:
alter default privileges in schema pendingbot
  grant select, insert, update, delete on tables to authenticated;
alter default privileges in schema pendingbot
  grant select on tables to anon;
