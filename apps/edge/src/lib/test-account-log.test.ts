import { describe, expect, it } from 'vitest';
import { summarizeQueryKeys, TEST_ACCOUNT_LOG_RETENTION_DAYS } from './test-account-log';

describe('test account logging privacy', () => {
  it('stores query keys instead of query values', () => {
    expect(
      summarizeQueryKeys({
        q: 'private search',
        token: 'secret',
        page: '2',
      }),
    ).toEqual(['page', 'q', 'token']);
  });

  it('keeps test-account request logs short-lived', () => {
    expect(TEST_ACCOUNT_LOG_RETENTION_DAYS).toBeLessThanOrEqual(14);
  });
});
