-- Billing v2 schema (see docs/billing-v2-design.md r2)
--
-- This migration is ADDITIVE — it does not touch v1 tables
-- (users.balance_credits / audit_log.cost_credits / billing_ledger /
-- topups / subject_wallets / group_member_billing / billing_config).
-- v1 stays as the running system until we cut over endpoint-by-endpoint;
-- the deprecate-v1 migration comes last.
--
-- Six tables, no RPCs (those land in a follow-up migration after the
-- edge code paths exist to test them):
--
--   packs                   user/subject prepaid PNC packs (FIFO consumed)
--   usage_events            per provider call usage record (raw cost)
--   ledger_entries          immutable pack debit/credit log
--   group_pools             share-index state per group subject
--   group_contributions     per-user contribution tracking for refunds
--   refund_events           Apple/LS chargeback audit trail
--
-- Polymorphic owner: every pack/usage_event/ledger_entry belongs to
-- exactly one of {user, subject}. Modelled with two FK columns +
-- a CHECK so referential integrity is preserved without forcing
-- parallel user_packs / subject_packs tables.

BEGIN;

-- ============================================================
-- 1. packs — prepaid PNC packs (the wallet primitive)
-- ============================================================
CREATE TABLE pendingbot.packs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Polymorphic owner. Exactly one of owner_user_id / owner_subject_id is set.
  owner_user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  owner_subject_id uuid REFERENCES pendingbot.subjects(id) ON DELETE CASCADE,
  owner_kind text GENERATED ALWAYS AS (
    CASE
      WHEN owner_user_id IS NOT NULL THEN 'user'
      WHEN owner_subject_id IS NOT NULL THEN 'subject'
    END
  ) STORED,

  initial_pnc_micros bigint NOT NULL CHECK (initial_pnc_micros >= 0),
  remaining_pnc_micros bigint NOT NULL CHECK (remaining_pnc_micros >= 0),

  expires_at timestamptz,  -- NULL = never expires (long-term pack)
  status text NOT NULL DEFAULT 'active' CHECK (status IN (
    'active',     -- consumable
    'exhausted',  -- remaining_pnc_micros = 0 from debits
    'expired',    -- past expires_at; remaining wiped to 0 by cron
    'refunded'    -- IAP/LS refund or group_refund withdrew the pack
  )),

  sales_channel text NOT NULL CHECK (sales_channel IN (
    'iap_ios',
    'iap_macos',
    'lemon_squeezy',
    'admin_grant',
    'group_topup',     -- pack issued to a group subject by member contribution
    'group_refund',    -- pack issued back to a user when leaving a group
    'v1_migration'     -- bootstrap pack for migrating v1 balance_credits
  )),

  -- IAP / LS dedup. Apple transactionId or LS order id. NULL for non-payment channels.
  external_purchase_id text,

  gross_paid_usd_cents integer,            -- user's actual payment
  net_revenue_usd_cents integer,           -- after Apple/LS cut
  sales_markup_snapshot numeric(10, 4),    -- markup at issue time (audit, not used at runtime)

  created_at timestamptz NOT NULL DEFAULT now(),
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,

  CONSTRAINT packs_owner_exactly_one CHECK (
    (owner_user_id IS NOT NULL)::int + (owner_subject_id IS NOT NULL)::int = 1
  ),
  CONSTRAINT packs_remaining_lte_initial CHECK (remaining_pnc_micros <= initial_pnc_micros)
);

-- FIFO consumption indexes: most-imminent-expiry first, then oldest.
CREATE INDEX packs_user_active_consume_idx
  ON pendingbot.packs (owner_user_id, expires_at NULLS LAST, created_at)
  WHERE status = 'active' AND owner_user_id IS NOT NULL;

CREATE INDEX packs_subject_active_consume_idx
  ON pendingbot.packs (owner_subject_id, expires_at NULLS LAST, created_at)
  WHERE status = 'active' AND owner_subject_id IS NOT NULL;

-- Expiry sweep cron index.
CREATE INDEX packs_expires_at_active_idx
  ON pendingbot.packs (expires_at)
  WHERE status = 'active' AND expires_at IS NOT NULL;

-- IAP / LS webhook idempotency.
CREATE UNIQUE INDEX packs_external_purchase_id_uidx
  ON pendingbot.packs (external_purchase_id)
  WHERE external_purchase_id IS NOT NULL;

COMMENT ON TABLE pendingbot.packs IS
  'Billing v2 prepaid PNC packs. Replaces users.balance_credits / subject_wallets.balance_credits. Consumed FIFO by expires_at NULLS LAST, created_at ASC.';

-- ============================================================
-- 2. usage_events — raw provider cost records
-- ============================================================
CREATE TABLE pendingbot.usage_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  owner_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  owner_subject_id uuid REFERENCES pendingbot.subjects(id) ON DELETE SET NULL,
  owner_kind text GENERATED ALWAYS AS (
    CASE
      WHEN owner_user_id IS NOT NULL THEN 'user'
      WHEN owner_subject_id IS NOT NULL THEN 'subject'
    END
  ) STORED,

  conversation_id uuid REFERENCES pendingbot.conversations(id) ON DELETE SET NULL,
  audit_log_id uuid REFERENCES pendingbot.audit_log(id) ON DELETE SET NULL,

  event_category text NOT NULL CHECK (event_category IN (
    'llm_tokens',
    'server_side_tools',
    'web_tools',
    'voice_tokens',
    'realtimekit_media',
    'sandbox_runtime',
    'storage_transfer',
    'push_delivery'
  )),

  provider text NOT NULL,        -- 'openai' / 'anthropic' / 'openrouter' / 'exa' / 'cloudflare' ...
  vendor_sku text,               -- 'gpt-5' / 'web_search_preview' / 'exa-search' ...
  model_id text,                 -- when applicable

  quantity numeric(20, 6) NOT NULL,
  quantity_unit text NOT NULL CHECK (quantity_unit IN (
    'tokens',
    'calls',
    'minutes',
    'seconds',
    'bytes',
    'mb',
    'gb'
  )),

  vendor_cost_usd numeric(20, 10) NOT NULL,
  pnc_micros bigint NOT NULL,

  cost_source text NOT NULL CHECK (cost_source IN (
    'gateway',
    'provider',
    'local_pricebook',
    'manual'
  )),

  raw_usage jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT usage_events_owner_exactly_one CHECK (
    (owner_user_id IS NOT NULL)::int + (owner_subject_id IS NOT NULL)::int = 1
  )
);

CREATE INDEX usage_events_user_recent_idx
  ON pendingbot.usage_events (owner_user_id, created_at DESC)
  WHERE owner_user_id IS NOT NULL;

CREATE INDEX usage_events_subject_recent_idx
  ON pendingbot.usage_events (owner_subject_id, created_at DESC)
  WHERE owner_subject_id IS NOT NULL;

CREATE INDEX usage_events_audit_log_idx
  ON pendingbot.usage_events (audit_log_id)
  WHERE audit_log_id IS NOT NULL;

CREATE INDEX usage_events_conversation_idx
  ON pendingbot.usage_events (conversation_id, created_at DESC)
  WHERE conversation_id IS NOT NULL;

CREATE INDEX usage_events_category_recent_idx
  ON pendingbot.usage_events (event_category, created_at DESC);

COMMENT ON TABLE pendingbot.usage_events IS
  'Billing v2 raw usage records. One row per provider call / metered slice. Drives ledger debits via settleUsage().';

-- ============================================================
-- 3. ledger_entries — append-only pack movements
-- ============================================================
CREATE TABLE pendingbot.ledger_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  owner_user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  owner_subject_id uuid REFERENCES pendingbot.subjects(id) ON DELETE CASCADE,
  owner_kind text GENERATED ALWAYS AS (
    CASE
      WHEN owner_user_id IS NOT NULL THEN 'user'
      WHEN owner_subject_id IS NOT NULL THEN 'subject'
    END
  ) STORED,

  pack_id uuid REFERENCES pendingbot.packs(id) ON DELETE SET NULL,
  usage_event_id uuid REFERENCES pendingbot.usage_events(id) ON DELETE SET NULL,

  entry_type text NOT NULL CHECK (entry_type IN (
    'debit',         -- pack consumed for a usage event
    'credit',        -- pack issued (topup)
    'release',       -- reserve release (unused in v2, reserved for future)
    'adjustment',    -- admin grant / claw-back
    'refund',        -- IAP/LS refund processed
    'expired',       -- pack expiry wrote off remaining
    'group_topup',   -- user → group subject contribution
    'group_refund',  -- group → user share-out on leave/dissolve
    'overdraft'      -- one-shot overdraft buffer charge
  )),

  delta_pnc_micros bigint NOT NULL,        -- signed; debit = negative
  balance_after_pnc_micros bigint NOT NULL,

  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT ledger_entries_owner_exactly_one CHECK (
    (owner_user_id IS NOT NULL)::int + (owner_subject_id IS NOT NULL)::int = 1
  )
);

CREATE INDEX ledger_entries_user_recent_idx
  ON pendingbot.ledger_entries (owner_user_id, created_at DESC)
  WHERE owner_user_id IS NOT NULL;

CREATE INDEX ledger_entries_subject_recent_idx
  ON pendingbot.ledger_entries (owner_subject_id, created_at DESC)
  WHERE owner_subject_id IS NOT NULL;

CREATE INDEX ledger_entries_pack_idx
  ON pendingbot.ledger_entries (pack_id, created_at)
  WHERE pack_id IS NOT NULL;

CREATE INDEX ledger_entries_usage_event_idx
  ON pendingbot.ledger_entries (usage_event_id)
  WHERE usage_event_id IS NOT NULL;

COMMENT ON TABLE pendingbot.ledger_entries IS
  'Billing v2 append-only ledger. Every pack debit / credit / adjustment / refund / expiry writes a row. Source of truth for wallet history.';

-- ============================================================
-- 4. group_pools — share-index state per group subject
-- ============================================================
CREATE TABLE pendingbot.group_pools (
  subject_id uuid PRIMARY KEY REFERENCES pendingbot.subjects(id) ON DELETE CASCADE,
  total_remaining_pnc_micros bigint NOT NULL DEFAULT 0
    CHECK (total_remaining_pnc_micros >= 0),
  share_index numeric(40, 20) NOT NULL DEFAULT 1.0
    CHECK (share_index > 0),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE pendingbot.group_pools IS
  'Per-subject share-index pool state for group wallets. share_index decays as the group spends; each contribution snapshots share_index_at_join so its current basis = contributed * pool.share_index / share_index_at_join.';

-- ============================================================
-- 5. group_contributions — per-user contribution tracking
-- ============================================================
CREATE TABLE pendingbot.group_contributions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_id uuid NOT NULL REFERENCES pendingbot.subjects(id) ON DELETE CASCADE,
  contributor_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  contributed_pnc_micros bigint NOT NULL CHECK (contributed_pnc_micros > 0),
  share_index_at_join numeric(40, 20) NOT NULL CHECK (share_index_at_join > 0),

  -- Source pack if contribution came from user's wallet (group_topup ledger);
  -- NULL if user directly IAP-funded the group subject.
  source_pack_id uuid REFERENCES pendingbot.packs(id) ON DELETE SET NULL,

  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'refunded')),

  created_at timestamptz NOT NULL DEFAULT now(),
  refunded_at timestamptz,

  CONSTRAINT group_contributions_refund_consistency CHECK (
    (status = 'refunded' AND refunded_at IS NOT NULL) OR
    (status = 'active' AND refunded_at IS NULL)
  )
);

CREATE INDEX group_contributions_subject_active_idx
  ON pendingbot.group_contributions (subject_id, created_at)
  WHERE status = 'active';

CREATE INDEX group_contributions_user_idx
  ON pendingbot.group_contributions (contributor_user_id, created_at DESC);

CREATE INDEX group_contributions_source_pack_idx
  ON pendingbot.group_contributions (source_pack_id)
  WHERE source_pack_id IS NOT NULL;

COMMENT ON TABLE pendingbot.group_contributions IS
  'Per-user contribution rows for the share-index group wallet model. Active rows back the group_pools balance; refunded rows are audit-only.';

-- ============================================================
-- 6. refund_events — Apple ASN V2 / Lemon Squeezy chargeback audit
-- ============================================================
CREATE TABLE pendingbot.refund_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  source text NOT NULL CHECK (source IN ('apple', 'lemon_squeezy', 'manual')),
  external_refund_id text NOT NULL,

  pack_id uuid REFERENCES pendingbot.packs(id) ON DELETE SET NULL,

  refund_amount_usd_cents integer NOT NULL,
  consumed_pnc_micros_at_refund bigint NOT NULL DEFAULT 0,
  chargeback_loss_pnc_micros bigint NOT NULL DEFAULT 0,

  raw_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX refund_events_source_external_uidx
  ON pendingbot.refund_events (source, external_refund_id);

CREATE INDEX refund_events_pack_idx
  ON pendingbot.refund_events (pack_id)
  WHERE pack_id IS NOT NULL;

COMMENT ON TABLE pendingbot.refund_events IS
  'Apple ASN V2 / Lemon Squeezy refund webhook trail. One row per refund. consumed_at_refund and chargeback_loss let admin audit how much of a refunded purchase was already spent.';

-- ============================================================
-- 7. RLS
-- ============================================================

ALTER TABLE pendingbot.packs ENABLE ROW LEVEL SECURITY;
CREATE POLICY packs_owner_read ON pendingbot.packs FOR SELECT TO authenticated
  USING (
    owner_user_id = auth.uid()
    OR (owner_subject_id IS NOT NULL
        AND pendingbot.subject_has_user_access(owner_subject_id, auth.uid()))
  );
GRANT SELECT ON TABLE pendingbot.packs TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.packs TO service_role;

ALTER TABLE pendingbot.usage_events ENABLE ROW LEVEL SECURITY;
CREATE POLICY usage_events_owner_read ON pendingbot.usage_events FOR SELECT TO authenticated
  USING (
    owner_user_id = auth.uid()
    OR (owner_subject_id IS NOT NULL
        AND pendingbot.subject_has_user_access(owner_subject_id, auth.uid()))
  );
GRANT SELECT ON TABLE pendingbot.usage_events TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.usage_events TO service_role;

ALTER TABLE pendingbot.ledger_entries ENABLE ROW LEVEL SECURITY;
CREATE POLICY ledger_entries_owner_read ON pendingbot.ledger_entries FOR SELECT TO authenticated
  USING (
    owner_user_id = auth.uid()
    OR (owner_subject_id IS NOT NULL
        AND pendingbot.subject_has_user_access(owner_subject_id, auth.uid()))
  );
GRANT SELECT ON TABLE pendingbot.ledger_entries TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.ledger_entries TO service_role;

ALTER TABLE pendingbot.group_pools ENABLE ROW LEVEL SECURITY;
CREATE POLICY group_pools_member_read ON pendingbot.group_pools FOR SELECT TO authenticated
  USING (pendingbot.subject_has_user_access(subject_id, auth.uid()));
GRANT SELECT ON TABLE pendingbot.group_pools TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.group_pools TO service_role;

ALTER TABLE pendingbot.group_contributions ENABLE ROW LEVEL SECURITY;
CREATE POLICY group_contributions_member_read ON pendingbot.group_contributions
  FOR SELECT TO authenticated
  USING (
    contributor_user_id = auth.uid()
    OR pendingbot.subject_has_user_access(subject_id, auth.uid())
  );
GRANT SELECT ON TABLE pendingbot.group_contributions TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.group_contributions TO service_role;

-- refund_events is admin-only; users see refund effects via ledger_entries
-- where entry_type='refund' (those are readable through pack ownership).
ALTER TABLE pendingbot.refund_events ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.refund_events TO service_role;

COMMIT;
