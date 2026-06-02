import { describe, expect, it, vi } from 'vitest';
import { wallet } from './wallet-client';

function fakeEnv(reply: unknown) {
  const fetchMock = vi.fn().mockResolvedValue(
    new Response(JSON.stringify(reply), { headers: { 'content-type': 'application/json' } }),
  );
  const idFromName = vi.fn().mockReturnValue('id-obj');
  const get = vi.fn().mockReturnValue({ fetch: fetchMock });
  return { env: { WALLET: { idFromName, get } } as any, fetchMock, idFromName, get };
}

describe('wallet-client', () => {
  it('routes to the subject DO and posts gate', async () => {
    const { env, fetchMock, idFromName } = fakeEnv({ balanceMicros: 100, thresholdState: 'sufficient' });
    const r = await wallet.gate(env, 'subject_1');
    expect(idFromName).toHaveBeenCalledWith('subject_1');
    const [url, init] = fetchMock.mock.calls[0];
    expect(String(url)).toContain('/gate');
    expect(JSON.parse(init.body).subjectId).toBe('subject_1');
    expect(r.thresholdState).toBe('sufficient');
  });

  it('debit passes pncMicros + dedupe + category', async () => {
    const { env, fetchMock } = fakeEnv({ balanceMicros: -2700, thresholdState: 'exhausted' });
    await wallet.debit(env, 's1', 2700, { category: 'llm_tokens', dedupeId: 'evt_1' });
    const body = JSON.parse(fetchMock.mock.calls[0][1].body);
    expect(body.pncMicros).toBe(2700);
    expect(body.category).toBe('llm_tokens');
    expect(body.dedupeId).toBe('evt_1');
  });

  it('applyAbsolute passes polar balance', async () => {
    const { env, fetchMock } = fakeEnv({ balanceMicros: 5, thresholdState: 'throttle' });
    await wallet.applyAbsolute(env, 's1', 5);
    const body = JSON.parse(fetchMock.mock.calls[0][1].body);
    expect(body.polarBalanceMicros).toBe(5);
    expect(String(fetchMock.mock.calls[0][0])).toContain('/apply-absolute');
  });
});
