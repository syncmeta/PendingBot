-- Group chat — schema layer (tables, columns, RLS).
-- RPCs follow in 0044. Splitting keeps each file scannable.
--
-- Design summary (full plan in repo `.claude/plans/indexed-scribbling-parasol.md`):
-- - Reuse `conversations(conversation_type='group', bot_id=NULL)` rather than
--   a separate `groups` table — group-only fields live in
--   `conversation_group_meta` (1:1 sidecar).
-- - Reuse `is_participant(conv_id)` for read RLS on every new table; that
--   function (0001) is SECURITY DEFINER and works for groups unchanged.
-- - Reuse `messages.role='log' + log_kind` to render the "continue?"
--   system bubble — no new role enum needed.
-- - Cost-split detail goes in a side table `audit_log_splits`; we don't
--   widen `audit_log` itself, since RLS on jsonb-of-uuids would be
--   awkward and many rows are 1-share user_bot calls anyway.

BEGIN;

-- ─────────────────────────────────────────────────────────────────────
-- Enums
-- ─────────────────────────────────────────────────────────────────────

CREATE TYPE pendingbot.group_join_policy AS ENUM (
  'scan_open',  -- scan QR / know the number → instantly join
  'approval',   -- request → owner/admin approves
  'closed'      -- no new members at all (only direct invite by admin)
);

CREATE TYPE pendingbot.group_split_mode AS ENUM (
  'custom',       -- explicit weights in group_billing_custom_shares
  'per_head',     -- 1/N over participating non-overdrawn members
  'per_message',  -- by human-message count over the rolling window
  'per_token',    -- by human-message token estimate over the window
  'hybrid'        -- 50% per_message + 50% per_token (default)
);

CREATE TYPE pendingbot.join_request_status AS ENUM (
  'pending', 'approved', 'rejected', 'expired'
);

CREATE TYPE pendingbot.continue_request_status AS ENUM (
  'pending', 'allowed', 'denied', 'expired'
);

-- ─────────────────────────────────────────────────────────────────────
-- conversation_group_meta — 1:1 sidecar to conversations for groups
-- ─────────────────────────────────────────────────────────────────────

CREATE TABLE pendingbot.conversation_group_meta (
    conversation_id uuid NOT NULL,
    title text,
    avatar_url text,
    join_policy pendingbot.group_join_policy DEFAULT 'approval' NOT NULL,
    -- NULL → use task_routing_rules('group_router') global default;
    -- non-NULL overrides for THIS group only.
    router_model_slug text,
    -- Hard cap on member count (humans + bots). 100 per spec.
    max_members smallint DEFAULT 100 NOT NULL,
    created_by uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT conversation_group_meta_pkey PRIMARY KEY (conversation_id),
    CONSTRAINT conversation_group_meta_max_members_chk
      CHECK (max_members > 0 AND max_members <= 100),
    CONSTRAINT conversation_group_meta_conv_fkey
      FOREIGN KEY (conversation_id) REFERENCES pendingbot.conversations(id)
      ON DELETE CASCADE,
    CONSTRAINT conversation_group_meta_created_by_fkey
      FOREIGN KEY (created_by) REFERENCES auth.users(id)
);
ALTER TABLE pendingbot.conversation_group_meta OWNER TO postgres;

ALTER TABLE pendingbot.conversation_group_meta ENABLE ROW LEVEL SECURITY;

CREATE POLICY group_meta_participant_read
  ON pendingbot.conversation_group_meta FOR SELECT
  USING (pendingbot.is_participant(conversation_id));
-- writes only via SECURITY DEFINER RPCs (0044) — no client-direct policies.

GRANT SELECT ON TABLE pendingbot.conversation_group_meta TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE pendingbot.conversation_group_meta TO service_role;

-- ─────────────────────────────────────────────────────────────────────
-- group_join_handles — per-group 'number' + 'qr' values, like user_handles
-- ─────────────────────────────────────────────────────────────────────

CREATE TABLE pendingbot.group_join_handles (
    id uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    conversation_id uuid NOT NULL,
    handle_type text NOT NULL,
    -- Same charset rule as user_handles to keep scan / paste behaviour
    -- identical: 4–20 chars of [A-Za-z0-9_-].
    value text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT group_join_handles_pkey PRIMARY KEY (id),
    CONSTRAINT group_join_handles_handle_type_chk
      CHECK (handle_type IN ('number', 'qr')),
    CONSTRAINT group_join_handles_value_chk
      CHECK (value ~ '^[A-Za-z0-9_-]{4,20}$'),
    -- Globally unique to share namespace with user_handles via the edge
    -- lookup — the worker resolves a scanned/typed value by trying both
    -- tables. Conflicts on insert surface as plain unique-violation.
    CONSTRAINT group_join_handles_value_uniq UNIQUE (value),
    -- One number + one QR max per group.
    CONSTRAINT group_join_handles_one_per_type
      UNIQUE (conversation_id, handle_type),
    CONSTRAINT group_join_handles_conv_fkey
      FOREIGN KEY (conversation_id) REFERENCES pendingbot.conversations(id)
      ON DELETE CASCADE
);
ALTER TABLE pendingbot.group_join_handles OWNER TO postgres;

ALTER TABLE pendingbot.group_join_handles ENABLE ROW LEVEL SECURITY;

CREATE POLICY group_handles_participant_read
  ON pendingbot.group_join_handles FOR SELECT
  USING (pendingbot.is_participant(conversation_id));
-- Anyone authed must be able to *resolve* a handle they typed/scanned
-- to find the group, even before joining. The edge does that resolve
-- via service_role to avoid leaking the membership graph.

GRANT SELECT ON TABLE pendingbot.group_join_handles TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE pendingbot.group_join_handles TO service_role;

-- ─────────────────────────────────────────────────────────────────────
-- group_join_requests — pending approvals when join_policy='approval'
-- ─────────────────────────────────────────────────────────────────────

CREATE TABLE pendingbot.group_join_requests (
    id uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    conversation_id uuid NOT NULL,
    requester_id uuid NOT NULL,
    via_handle_id uuid,
    status pendingbot.join_request_status DEFAULT 'pending' NOT NULL,
    message text,
    decided_by uuid,
    decided_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT group_join_requests_pkey PRIMARY KEY (id),
    CONSTRAINT group_join_requests_conv_fkey
      FOREIGN KEY (conversation_id) REFERENCES pendingbot.conversations(id)
      ON DELETE CASCADE,
    CONSTRAINT group_join_requests_requester_fkey
      FOREIGN KEY (requester_id) REFERENCES auth.users(id)
      ON DELETE CASCADE,
    CONSTRAINT group_join_requests_handle_fkey
      FOREIGN KEY (via_handle_id) REFERENCES pendingbot.group_join_handles(id)
      ON DELETE SET NULL,
    CONSTRAINT group_join_requests_decided_by_fkey
      FOREIGN KEY (decided_by) REFERENCES auth.users(id)
      ON DELETE SET NULL
);
ALTER TABLE pendingbot.group_join_requests OWNER TO postgres;

-- Only one pending request per (group, user). Settled rows accumulate.
CREATE UNIQUE INDEX idx_group_join_requests_one_pending
  ON pendingbot.group_join_requests (conversation_id, requester_id)
  WHERE status = 'pending';

CREATE INDEX idx_group_join_requests_inbox
  ON pendingbot.group_join_requests (conversation_id, status, created_at);

ALTER TABLE pendingbot.group_join_requests ENABLE ROW LEVEL SECURITY;

-- Requester sees their own request; admins/owners of the group see all.
CREATE POLICY join_requests_self_read
  ON pendingbot.group_join_requests FOR SELECT
  USING (requester_id = auth.uid());

CREATE POLICY join_requests_admin_read
  ON pendingbot.group_join_requests FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM pendingbot.conversation_participants cp
       WHERE cp.conversation_id = group_join_requests.conversation_id
         AND cp.participant_type = 'user'
         AND cp.participant_id = auth.uid()
         AND cp.role IN ('owner', 'admin')
    )
  );

GRANT SELECT ON TABLE pendingbot.group_join_requests TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE pendingbot.group_join_requests TO service_role;

-- ─────────────────────────────────────────────────────────────────────
-- group_billing_config — one row per group; defaults to 'hybrid'
-- ─────────────────────────────────────────────────────────────────────

CREATE TABLE pendingbot.group_billing_config (
    conversation_id uuid NOT NULL,
    mode pendingbot.group_split_mode DEFAULT 'hybrid' NOT NULL,
    -- Rolling window for per_message / per_token computation.
    window_seconds integer DEFAULT 86400 NOT NULL,
    -- Newcomers in their first N seconds get per_head fallback so they
    -- can't be charged 100% before their first message lands.
    new_member_grace_seconds integer DEFAULT 86400 NOT NULL,
    updated_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT group_billing_config_pkey PRIMARY KEY (conversation_id),
    CONSTRAINT group_billing_config_window_chk
      CHECK (window_seconds > 0 AND window_seconds <= 30 * 86400),
    CONSTRAINT group_billing_config_grace_chk
      CHECK (new_member_grace_seconds >= 0
             AND new_member_grace_seconds <= 30 * 86400),
    CONSTRAINT group_billing_config_conv_fkey
      FOREIGN KEY (conversation_id) REFERENCES pendingbot.conversations(id)
      ON DELETE CASCADE,
    CONSTRAINT group_billing_config_updated_by_fkey
      FOREIGN KEY (updated_by) REFERENCES auth.users(id)
      ON DELETE SET NULL
);
ALTER TABLE pendingbot.group_billing_config OWNER TO postgres;

ALTER TABLE pendingbot.group_billing_config ENABLE ROW LEVEL SECURITY;

CREATE POLICY group_billing_config_participant_read
  ON pendingbot.group_billing_config FOR SELECT
  USING (pendingbot.is_participant(conversation_id));

GRANT SELECT ON TABLE pendingbot.group_billing_config TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE pendingbot.group_billing_config TO service_role;

-- ─────────────────────────────────────────────────────────────────────
-- group_billing_custom_shares — per-user weights when mode='custom'
-- Triggers enforce sum=10000 on INSERT/UPDATE/DELETE.
-- ─────────────────────────────────────────────────────────────────────

CREATE TABLE pendingbot.group_billing_custom_shares (
    conversation_id uuid NOT NULL,
    user_id uuid NOT NULL,
    weight_bps integer NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT group_billing_custom_shares_pkey
      PRIMARY KEY (conversation_id, user_id),
    CONSTRAINT group_billing_custom_shares_weight_chk
      CHECK (weight_bps >= 0 AND weight_bps <= 10000),
    CONSTRAINT group_billing_custom_shares_conv_fkey
      FOREIGN KEY (conversation_id) REFERENCES pendingbot.conversations(id)
      ON DELETE CASCADE,
    CONSTRAINT group_billing_custom_shares_user_fkey
      FOREIGN KEY (user_id) REFERENCES auth.users(id)
      ON DELETE CASCADE
);
ALTER TABLE pendingbot.group_billing_custom_shares OWNER TO postgres;

ALTER TABLE pendingbot.group_billing_custom_shares ENABLE ROW LEVEL SECURITY;

CREATE POLICY group_custom_shares_participant_read
  ON pendingbot.group_billing_custom_shares FOR SELECT
  USING (pendingbot.is_participant(conversation_id));

GRANT SELECT ON TABLE pendingbot.group_billing_custom_shares TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE pendingbot.group_billing_custom_shares TO service_role;

-- ─────────────────────────────────────────────────────────────────────
-- group_member_billing — per-(group,user) caps and rolling spend
-- ─────────────────────────────────────────────────────────────────────

CREATE TABLE pendingbot.group_member_billing (
    conversation_id uuid NOT NULL,
    user_id uuid NOT NULL,
    -- Owner/admin can flip a member out of cost sharing without kicking
    -- them. Default true.
    participates boolean DEFAULT true NOT NULL,
    -- NULL = no per-group cap (still bound by user's overall balance).
    cap_credits bigint,
    spent_credits bigint DEFAULT 0 NOT NULL,
    -- True when balance or cap exhausted; excluded from next split.
    -- Recomputed by group-billing.ts after each debit.
    overdrawn boolean DEFAULT false NOT NULL,
    -- iOS toggle: don't push notify for new messages in this group.
    muted boolean DEFAULT false NOT NULL,
    joined_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT group_member_billing_pkey
      PRIMARY KEY (conversation_id, user_id),
    CONSTRAINT group_member_billing_cap_chk
      CHECK (cap_credits IS NULL OR cap_credits >= 0),
    CONSTRAINT group_member_billing_spent_chk
      CHECK (spent_credits >= 0),
    CONSTRAINT group_member_billing_conv_fkey
      FOREIGN KEY (conversation_id) REFERENCES pendingbot.conversations(id)
      ON DELETE CASCADE,
    CONSTRAINT group_member_billing_user_fkey
      FOREIGN KEY (user_id) REFERENCES auth.users(id)
      ON DELETE CASCADE
);
ALTER TABLE pendingbot.group_member_billing OWNER TO postgres;

CREATE INDEX idx_group_member_billing_user
  ON pendingbot.group_member_billing(user_id);

ALTER TABLE pendingbot.group_member_billing ENABLE ROW LEVEL SECURITY;

-- Members see their own row + admin sees all rows in their group.
-- Splitting into two policies keeps each one a simple OR; PG combines
-- them with OR for SELECT.
CREATE POLICY group_member_billing_self_read
  ON pendingbot.group_member_billing FOR SELECT
  USING (user_id = auth.uid());

CREATE POLICY group_member_billing_admin_read
  ON pendingbot.group_member_billing FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM pendingbot.conversation_participants cp
       WHERE cp.conversation_id = group_member_billing.conversation_id
         AND cp.participant_type = 'user'
         AND cp.participant_id = auth.uid()
         AND cp.role IN ('owner', 'admin')
    )
  );

GRANT SELECT ON TABLE pendingbot.group_member_billing TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE pendingbot.group_member_billing TO service_role;

-- ─────────────────────────────────────────────────────────────────────
-- group_bot_descriptions — per-group bot self-description ("call me
-- when…"). The bot is required to write the first version on join (and
-- the call is billed to the group). After that, the bot may rewrite it
-- via tool — sparingly; the system prompt warns against churn.
-- ─────────────────────────────────────────────────────────────────────

CREATE TABLE pendingbot.group_bot_descriptions (
    conversation_id uuid NOT NULL,
    bot_id uuid NOT NULL,
    description text NOT NULL,
    -- Number of times the bot has rewritten this row (UI / future
    -- rate-limiting may use this).
    revision_count integer DEFAULT 0 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT group_bot_descriptions_pkey
      PRIMARY KEY (conversation_id, bot_id),
    CONSTRAINT group_bot_descriptions_conv_fkey
      FOREIGN KEY (conversation_id) REFERENCES pendingbot.conversations(id)
      ON DELETE CASCADE,
    CONSTRAINT group_bot_descriptions_bot_fkey
      FOREIGN KEY (bot_id) REFERENCES pendingbot.bots(id)
      ON DELETE CASCADE
);
ALTER TABLE pendingbot.group_bot_descriptions OWNER TO postgres;

ALTER TABLE pendingbot.group_bot_descriptions ENABLE ROW LEVEL SECURITY;

CREATE POLICY group_bot_desc_participant_read
  ON pendingbot.group_bot_descriptions FOR SELECT
  USING (pendingbot.is_participant(conversation_id));

GRANT SELECT ON TABLE pendingbot.group_bot_descriptions TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE pendingbot.group_bot_descriptions TO service_role;

-- ─────────────────────────────────────────────────────────────────────
-- group_continue_requests — anti-loop "may the bot keep talking?" gate.
-- See plan §B/§"Bot 链式唤醒". Triggered by group-dispatch when the
-- last 30s of messages contains only bot output.
-- ─────────────────────────────────────────────────────────────────────

CREATE TABLE pendingbot.group_continue_requests (
    id uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    conversation_id uuid NOT NULL,
    -- Bots queued to speak this turn if humans say yes.
    pending_bot_ids uuid[] NOT NULL,
    status pendingbot.continue_request_status DEFAULT 'pending' NOT NULL,
    requested_at timestamp with time zone DEFAULT now() NOT NULL,
    decided_by uuid,
    decided_at timestamp with time zone,
    -- The user message that recorded the allow / deny decision (so
    -- everyone sees who said yes/no in the conversation log).
    decision_message_id uuid,
    -- The system 'log' message that asked the question, useful for
    -- the iOS bubble's "Approved by …" / "Vetoed by …" annotation.
    prompt_message_id uuid,
    CONSTRAINT group_continue_requests_pkey PRIMARY KEY (id),
    CONSTRAINT group_continue_requests_conv_fkey
      FOREIGN KEY (conversation_id) REFERENCES pendingbot.conversations(id)
      ON DELETE CASCADE,
    CONSTRAINT group_continue_requests_decided_by_fkey
      FOREIGN KEY (decided_by) REFERENCES auth.users(id)
      ON DELETE SET NULL,
    CONSTRAINT group_continue_requests_decision_msg_fkey
      FOREIGN KEY (decision_message_id) REFERENCES pendingbot.messages(id)
      ON DELETE SET NULL,
    CONSTRAINT group_continue_requests_prompt_msg_fkey
      FOREIGN KEY (prompt_message_id) REFERENCES pendingbot.messages(id)
      ON DELETE SET NULL
);
ALTER TABLE pendingbot.group_continue_requests OWNER TO postgres;

CREATE INDEX idx_group_continue_pending
  ON pendingbot.group_continue_requests(conversation_id, requested_at)
  WHERE status = 'pending';

ALTER TABLE pendingbot.group_continue_requests ENABLE ROW LEVEL SECURITY;

CREATE POLICY group_continue_participant_read
  ON pendingbot.group_continue_requests FOR SELECT
  USING (pendingbot.is_participant(conversation_id));

GRANT SELECT ON TABLE pendingbot.group_continue_requests TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE pendingbot.group_continue_requests TO service_role;

-- ─────────────────────────────────────────────────────────────────────
-- audit_log_splits — per-user split detail for one audit_log row.
-- One row per (audit_log_id, user_id). Sum of share_bps = 10000 across
-- non-skipped rows. Reads scoped to self + group admin.
-- ─────────────────────────────────────────────────────────────────────

CREATE TABLE pendingbot.audit_log_splits (
    audit_log_id uuid NOT NULL,
    user_id uuid NOT NULL,
    share_bps integer NOT NULL,
    debited_credits bigint DEFAULT 0 NOT NULL,
    debit_status text DEFAULT 'debited' NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT audit_log_splits_pkey
      PRIMARY KEY (audit_log_id, user_id),
    CONSTRAINT audit_log_splits_share_chk
      CHECK (share_bps >= 0 AND share_bps <= 10000),
    CONSTRAINT audit_log_splits_status_chk
      CHECK (debit_status IN ('debited', 'skipped_overdrawn', 'skipped_capped')),
    CONSTRAINT audit_log_splits_audit_fkey
      FOREIGN KEY (audit_log_id) REFERENCES pendingbot.audit_log(id)
      ON DELETE CASCADE,
    CONSTRAINT audit_log_splits_user_fkey
      FOREIGN KEY (user_id) REFERENCES auth.users(id)
      ON DELETE CASCADE
);
ALTER TABLE pendingbot.audit_log_splits OWNER TO postgres;

CREATE INDEX idx_audit_log_splits_user
  ON pendingbot.audit_log_splits(user_id, created_at DESC);

ALTER TABLE pendingbot.audit_log_splits ENABLE ROW LEVEL SECURITY;

CREATE POLICY audit_log_splits_self_read
  ON pendingbot.audit_log_splits FOR SELECT
  USING (user_id = auth.uid());

-- Group admin can see every split row tied to an audit_log row in their
-- group. Going through audit_log → conversation_id → participants.role.
CREATE POLICY audit_log_splits_admin_read
  ON pendingbot.audit_log_splits FOR SELECT
  USING (
    EXISTS (
      SELECT 1
        FROM pendingbot.audit_log al
        JOIN pendingbot.conversation_participants cp
          ON cp.conversation_id = al.conversation_id
       WHERE al.id = audit_log_splits.audit_log_id
         AND cp.participant_type = 'user'
         AND cp.participant_id = auth.uid()
         AND cp.role IN ('owner', 'admin')
    )
  );

GRANT SELECT ON TABLE pendingbot.audit_log_splits TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE pendingbot.audit_log_splits TO service_role;

-- ─────────────────────────────────────────────────────────────────────
-- conversation_participants — extend with nickname + muted + joined_at
-- ─────────────────────────────────────────────────────────────────────

ALTER TABLE pendingbot.conversation_participants
  ADD COLUMN nickname text;

ALTER TABLE pendingbot.conversation_participants
  ADD COLUMN muted boolean DEFAULT false NOT NULL;

-- Note: 0001 already defines `joined_at` (timestamp with time zone
-- DEFAULT now()) on this table — no migration needed for that column.

-- Group-scoped nickname uniqueness (case-insensitive). Partial so 1v1
-- convs (where nickname is always NULL) don't pay the index cost.
CREATE UNIQUE INDEX idx_participants_nickname_uniq
  ON pendingbot.conversation_participants
     (conversation_id, lower(nickname))
  WHERE nickname IS NOT NULL;

-- ─────────────────────────────────────────────────────────────────────
-- task_routing_rules — seed the 'group_router' task type so the board
-- has a row to point its global default at. override_model_id stays
-- NULL initially; bootstrapping the actual model row happens after
-- gemma is added to llm_models / llm_model_aliases (admin task).
-- Idempotent ON CONFLICT for re-runs.
-- ─────────────────────────────────────────────────────────────────────

INSERT INTO pendingbot.task_routing_rules
  (task_type, match_priority, enabled, override_model_id, prefer_provider_id, notes)
VALUES
  ('group_router', 100, true, NULL, NULL,
   'Small classifier model that decides which bots to wake on each group message. Default target: google/gemma-4-31b-it (set override_model_id once aliased).')
ON CONFLICT (task_type, match_priority) DO NOTHING;

COMMIT;
