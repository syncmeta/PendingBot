-- refund_events processing state.
--
-- The webhooks (lib/billing-v2-lemon.ts / lib/billing-v2-iap.ts) write
-- refund_events rows. The refund processor (lib/billing-v2-refund.ts)
-- later invalidates the pack, computes consumed_pnc_micros + chargeback
-- loss, and writes a refund ledger entry.
--
-- We need a way to query "unprocessed refunds" so the processor can
-- pick them up — webhooks call it eagerly via ctx.waitUntil(), but a
-- failure on the eager path leaves the row to be retried by the next
-- cron pass (#187).

BEGIN;

ALTER TABLE pendingbot.refund_events
  ADD COLUMN IF NOT EXISTS processed_at timestamptz,
  ADD COLUMN IF NOT EXISTS processing_error text;

-- Pending refunds = WHERE processed_at IS NULL. Index supports both the
-- eager path (one-shot lookup) and the cron sweep.
CREATE INDEX IF NOT EXISTS refund_events_pending_idx
  ON pendingbot.refund_events (created_at)
  WHERE processed_at IS NULL;

COMMENT ON COLUMN pendingbot.refund_events.processed_at IS
  'When the refund processor applied this event (pack invalidation + chargeback_loss accounting). NULL = pending.';
COMMENT ON COLUMN pendingbot.refund_events.processing_error IS
  'If processing failed, the error message. Cron retry overwrites on each attempt; permanent failures stay NULL processed_at + non-null error until admin clears.';

COMMIT;
