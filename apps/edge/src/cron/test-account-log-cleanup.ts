import type { Env } from '../types';
import { serviceClient } from '../lib/supabase';
import { TEST_ACCOUNT_LOG_RETENTION_DAYS } from '../lib/test-account-log';

export async function cleanupTestAccountLogs(env: Env): Promise<void> {
  const cutoff = new Date(
    Date.now() - TEST_ACCOUNT_LOG_RETENTION_DAYS * 24 * 60 * 60 * 1000,
  ).toISOString();
  const { error } = await serviceClient(env)
    .from('test_account_log')
    .delete()
    .lt('occurred_at', cutoff);
  if (error) {
    console.warn('[cron/test-account-log-cleanup] delete failed', error.message);
    return;
  }
  console.log('[cron/test-account-log-cleanup]', {
    retention_days: TEST_ACCOUNT_LOG_RETENTION_DAYS,
  });
}
