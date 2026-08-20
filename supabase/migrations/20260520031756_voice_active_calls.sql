-- Active group voice calls — a tiny index so the message list can show a
-- phone-icon badge on rows whose conversation has a live call without
-- waking the conversation's RoomVoiceDO.
--
-- RoomVoiceDO upserts a row when /control/start runs and deletes it from
-- finalize(). One row per conversation (PK) — calls are per-group and
-- one-at-a-time. Bound to the conversation lifecycle via cascade so a
-- group deletion doesn't leak orphan rows.
--
-- A row may rarely outlive the actual call (e.g. the DO died before
-- finalize ran). The 30-minute MAX_CALL_MS cap inside the DO bounds the
-- staleness window; reads should treat "started_at older than ~30min"
-- as suspect rather than authoritative. Future hardening can heartbeat.

create table if not exists pendingbot.voice_active_calls (
  conversation_id uuid primary key references pendingbot.conversations(id) on delete cascade,
  started_at      timestamptz not null default now(),
  initiator_id    uuid        not null
);

-- Read access through RLS: every user can see active calls for the
-- conversations they participate in. The DO writes via the service role,
-- so RLS only governs reads.
alter table pendingbot.voice_active_calls enable row level security;

create policy voice_active_calls_select on pendingbot.voice_active_calls
  for select using (
    exists (
      select 1
      from pendingbot.conversation_participants cp
      where cp.conversation_id = voice_active_calls.conversation_id
        and cp.participant_type = 'user'
        and cp.participant_id = auth.uid()
    )
  );
