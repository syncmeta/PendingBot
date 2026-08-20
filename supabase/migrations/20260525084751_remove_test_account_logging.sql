-- Remove test-account request logging entirely. Per-user debug logging was
-- useful pre-launch but creates a silent privacy dataset, so the product no
-- longer keeps a special request-log table or test-account flag.

BEGIN;

DROP TABLE IF EXISTS pendingbot.test_account_log;

ALTER TABLE pendingbot.users
  DROP COLUMN IF EXISTS is_test_account;

COMMIT;
