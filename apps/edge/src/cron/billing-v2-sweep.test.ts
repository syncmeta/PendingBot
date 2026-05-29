import { describe, expect, it, vi } from 'vitest';
import type { Env } from '../types';
import { expirePacks, reconcileGroupPools } from './billing-v2-sweep';

// These tests exercise the cron's SQL shape against a mock Supabase
// builder. They don't talk to a real database; the goal is to lock in
// the CAS predicates + ledger-row contents so a refactor can't silently
// degrade the safety guarantees (e.g. swapping the CAS for a plain
// update would let a race overwrite a settle).

interface RecordedUpdate {
  table: string;
  values: Record<string, unknown>;
  predicates: Array<[string, unknown]>;
}

interface RecordedInsert {
  table: string;
  payload: Record<string, unknown>;
}

function buildMockSupa(opts: {
  expiredPacks?: Array<{
    id: string;
    owner_user_id: string | null;
    owner_subject_id: string | null;
    remaining_pnc_micros: number;
  }>;
  pools?: Array<{ subject_id: string; total_remaining_pnc_micros: number }>;
  subjectPacksByOwner?: Record<string, Array<{ remaining_pnc_micros: number }>>;
  /** simulate a CAS loss by causing the update to return null */
  casLossPackIds?: Set<string>;
}) {
  const updates: RecordedUpdate[] = [];
  const inserts: RecordedInsert[] = [];

  function fromBuilder(table: string) {
    let select: 'pack-expiry-read' | 'pool-read' | 'pack-balance-recheck' | null = null;
    let predicates: Array<[string, unknown]> = [];
    let ownerFilter: { col: string; val: unknown } | null = null;

    const api = {
      select(cols: string) {
        if (table === 'packs' && cols.includes('owner_user_id') && cols.includes('owner_subject_id')) {
          select = 'pack-expiry-read';
        } else if (table === 'group_pools') {
          select = 'pool-read';
        } else if (table === 'packs' && cols === 'remaining_pnc_micros') {
          select = 'pack-balance-recheck';
        }
        return api;
      },
      eq(col: string, val: unknown) {
        predicates.push([col, val]);
        if (col === 'owner_user_id' || col === 'owner_subject_id') {
          ownerFilter = { col, val };
        }
        return api;
      },
      not() { return api; },
      lt() { return api; },
      limit() { return finalize(); },
      maybeSingle() { return finalize(); },
      async then(resolve: (r: unknown) => void) { resolve(finalize()); },
      update(values: Record<string, unknown>) {
        const upd = { table, values, predicates: [] as Array<[string, unknown]> };
        const updApi = {
          eq(col: string, val: unknown) {
            upd.predicates.push([col, val]);
            return updApi;
          },
          select() { return updApi; },
          maybeSingle: async () => {
            updates.push({ ...upd });
            const id = upd.predicates.find((p) => p[0] === 'id')?.[1] as string | undefined;
            if (id && opts.casLossPackIds?.has(id)) return { data: null, error: null };
            return { data: { id: id ?? 'x' }, error: null };
          },
        };
        return updApi;
      },
      insert(payload: Record<string, unknown>) {
        inserts.push({ table, payload });
        return { error: null };
      },
    };

    function finalize() {
      if (select === 'pack-expiry-read') {
        return { data: opts.expiredPacks ?? [], error: null };
      }
      if (select === 'pool-read') {
        return { data: opts.pools ?? [], error: null };
      }
      if (select === 'pack-balance-recheck') {
        const owner = ownerFilter?.val as string | null | undefined;
        return {
          data: owner ? (opts.subjectPacksByOwner?.[owner] ?? []) : [],
          error: null,
        };
      }
      return { data: null, error: null };
    }

    return api;
  }

  const supa = { from: fromBuilder } as unknown as ReturnType<
    typeof import('../lib/supabase').serviceClient
  >;
  return { supa, updates, inserts };
}

vi.mock('../lib/supabase', () => ({
  serviceClient: vi.fn(),
}));

import { serviceClient } from '../lib/supabase';
const serviceClientMock = serviceClient as unknown as ReturnType<typeof vi.fn>;

const env = {} as Env;

describe('expirePacks', () => {
  it('CAS predicate includes status=active AND old remaining', async () => {
    const { supa, updates, inserts } = buildMockSupa({
      expiredPacks: [
        {
          id: 'p1',
          owner_user_id: 'u1',
          owner_subject_id: null,
          remaining_pnc_micros: 1_500_000,
        },
      ],
      // After expiry the owner has one other pack with 2 PNC left.
      subjectPacksByOwner: { u1: [{ remaining_pnc_micros: 2_000_000 }] },
    });
    serviceClientMock.mockReturnValue(supa);
    const r = await expirePacks(env);
    expect(r).toEqual({ expired: 1, scanned: 1 });

    const upd = updates[0];
    expect(upd.values).toMatchObject({ status: 'expired', remaining_pnc_micros: 0 });
    const predKeys = upd.predicates.map((p) => p[0]);
    expect(predKeys).toContain('status');
    expect(predKeys).toContain('remaining_pnc_micros');
    expect(upd.predicates.find((p) => p[0] === 'status')?.[1]).toBe('active');
    expect(upd.predicates.find((p) => p[0] === 'remaining_pnc_micros')?.[1]).toBe(1_500_000);

    // Ledger row: balance_after is the post-expiry remaining (2 PNC), delta is -1.5 PNC
    expect(inserts).toHaveLength(1);
    expect(inserts[0].payload).toMatchObject({
      entry_type: 'expired',
      delta_pnc_micros: -1_500_000,
      balance_after_pnc_micros: 2_000_000,
      pack_id: 'p1',
      usage_event_id: null,
    });
  });

  it('skips ledger entry when expired pack had 0 remaining', async () => {
    const { supa, inserts } = buildMockSupa({
      expiredPacks: [
        {
          id: 'p2',
          owner_user_id: 'u2',
          owner_subject_id: null,
          remaining_pnc_micros: 0,
        },
      ],
      subjectPacksByOwner: { u2: [] },
    });
    serviceClientMock.mockReturnValue(supa);
    await expirePacks(env);
    // Pack flipped to expired but no ledger row (nothing to write off).
    expect(inserts).toHaveLength(0);
  });

  it('CAS loss → no ledger entry, no expired count', async () => {
    const { supa, inserts } = buildMockSupa({
      expiredPacks: [
        {
          id: 'p3',
          owner_user_id: 'u3',
          owner_subject_id: null,
          remaining_pnc_micros: 1_000_000,
        },
      ],
      casLossPackIds: new Set(['p3']),
    });
    serviceClientMock.mockReturnValue(supa);
    const r = await expirePacks(env);
    expect(r).toEqual({ expired: 0, scanned: 1 });
    expect(inserts).toHaveLength(0);
  });
});

describe('reconcileGroupPools', () => {
  it('flags drift when pool total disagrees with summed packs', async () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    const { supa } = buildMockSupa({
      pools: [{ subject_id: 's1', total_remaining_pnc_micros: 100 }],
      subjectPacksByOwner: { s1: [{ remaining_pnc_micros: 50 }] },
    });
    serviceClientMock.mockReturnValue(supa);
    const r = await reconcileGroupPools(env);
    expect(r).toEqual({ checked: 1, drifted: 1 });
    expect(warn).toHaveBeenCalled();
    const driftMsg = warn.mock.calls.find((c) =>
      String(c[0] ?? '').includes('DRIFT'),
    );
    expect(driftMsg).toBeTruthy();
    warn.mockRestore();
  });

  it('no warning when sums agree (within tolerance)', async () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    const { supa } = buildMockSupa({
      pools: [{ subject_id: 's2', total_remaining_pnc_micros: 1_000_000 }],
      subjectPacksByOwner: {
        s2: [
          { remaining_pnc_micros: 600_000 },
          { remaining_pnc_micros: 400_000 },
        ],
      },
    });
    serviceClientMock.mockReturnValue(supa);
    const r = await reconcileGroupPools(env);
    expect(r).toEqual({ checked: 1, drifted: 0 });
    const driftWarn = warn.mock.calls.find((c) =>
      String(c[0] ?? '').includes('DRIFT'),
    );
    expect(driftWarn).toBeUndefined();
    warn.mockRestore();
  });
});
