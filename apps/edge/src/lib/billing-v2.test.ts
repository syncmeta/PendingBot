import { describe, expect, it } from 'vitest';
import type { SupabaseClient } from './supabase';
import {
  OVERDRAFT_BUFFER_PNC_MICROS,
  PNC_MICROS_PER_PNC,
  PNC_MICROS_PER_USD,
  PNC_PER_USD,
  THRESHOLD_LOW_PNC_MICROS,
  THRESHOLD_THROTTLE_PNC_MICROS,
  defaultPackExpiresAt,
  getThresholdState,
  settleAuditUsage,
  settleUsage,
  usdToPncMicros,
} from './billing-v2';

describe('billing-v2 constants', () => {
  it('keeps the 27:1 ratio (product decision, not a bug)', () => {
    expect(PNC_PER_USD).toBe(27);
    expect(PNC_MICROS_PER_PNC).toBe(1_000_000);
    expect(PNC_MICROS_PER_USD).toBe(27_000_000);
  });

  it('low/throttle/overdraft thresholds match doc r2 §7', () => {
    expect(THRESHOLD_LOW_PNC_MICROS).toBe(50 * PNC_MICROS_PER_PNC);
    expect(THRESHOLD_THROTTLE_PNC_MICROS).toBe(5 * PNC_MICROS_PER_PNC);
    expect(OVERDRAFT_BUFFER_PNC_MICROS).toBe(500_000);
  });
});

describe('usdToPncMicros', () => {
  it('rounds 1 USD to exactly 27_000_000 micros', () => {
    expect(usdToPncMicros(1)).toBe(27_000_000);
  });

  it('rounds (not ceils) cheap calls to avoid systemic over-billing', () => {
    // 0.0001 USD * 27_000_000 = 2700 micros — round trip averages to 0.
    expect(usdToPncMicros(0.0001)).toBe(2700);
    // 0.00000001 USD = 0.27 micros; round → 0 (cheap call below grain).
    expect(usdToPncMicros(0.00000001)).toBe(0);
    // 0.00000002 USD = 0.54 micros; round → 1.
    expect(usdToPncMicros(0.00000002)).toBe(1);
  });

  it('clamps null / 0 / negative / non-finite to 0', () => {
    expect(usdToPncMicros(null)).toBe(0);
    expect(usdToPncMicros(undefined)).toBe(0);
    expect(usdToPncMicros(0)).toBe(0);
    expect(usdToPncMicros(-1)).toBe(0);
    expect(usdToPncMicros(Number.NaN)).toBe(0);
    expect(usdToPncMicros(Number.POSITIVE_INFINITY)).toBe(0);
  });
});

describe('getThresholdState', () => {
  it('≤ 0 → exhausted (hard stop, no-balance notice path)', () => {
    expect(getThresholdState(0)).toBe('exhausted');
    expect(getThresholdState(-1)).toBe('exhausted');
    expect(getThresholdState(-OVERDRAFT_BUFFER_PNC_MICROS)).toBe('exhausted');
  });

  it('(0, 5 PNC) → throttle (force cheap model, tools off)', () => {
    expect(getThresholdState(1)).toBe('throttle');
    expect(getThresholdState(PNC_MICROS_PER_PNC)).toBe('throttle');
    expect(getThresholdState(THRESHOLD_THROTTLE_PNC_MICROS - 1)).toBe('throttle');
  });

  it('[5 PNC, 50 PNC) → low (notice injected)', () => {
    expect(getThresholdState(THRESHOLD_THROTTLE_PNC_MICROS)).toBe('low');
    expect(getThresholdState(10 * PNC_MICROS_PER_PNC)).toBe('low');
    expect(getThresholdState(THRESHOLD_LOW_PNC_MICROS - 1)).toBe('low');
  });

  it('≥ 50 PNC → sufficient (no UX intervention)', () => {
    expect(getThresholdState(THRESHOLD_LOW_PNC_MICROS)).toBe('sufficient');
    expect(getThresholdState(1_000_000_000)).toBe('sufficient');
  });
});

describe('settleAuditUsage', () => {
  // Minimal mock that records every insert payload so the test can
  // assert exactly which usage_events were written. We don't need a real
  // pack/ledger flow here — the test for that lives in settleUsage. The
  // assertion is about the splitting logic: how settleAuditUsage breaks
  // a turn into per-category rows.
  type Recorded = { table: string; payload: unknown };
  function mockSupa(): { supa: SupabaseClient; recorded: Recorded[] } {
    const recorded: Recorded[] = [];
    const supa = {
      from(table: string) {
        return {
          insert(payload: unknown) {
            recorded.push({ table, payload });
            // settleUsage needs id back from usage_events insert
            const id = `${table}-${recorded.length}`;
            return {
              select() {
                return {
                  single: async () => ({ data: { id }, error: null }),
                };
              },
              // ledger_entries.insert is called without .select()
              then: (resolve: (v: { error: null }) => void) => resolve({ error: null }),
            };
          },
          select() {
            // packs select for FIFO walk + balance lookups — return empty
            // so settleUsage early-exits into the overdraft path.
            return {
              eq() {
                return {
                  eq() {
                    return {
                      order() {
                        return {
                          order() {
                            return {
                              limit: async () => ({ data: [], error: null }),
                            };
                          },
                        };
                      },
                    };
                  },
                };
              },
            };
          },
        };
      },
    } as unknown as SupabaseClient;
    return { supa, recorded };
  }

  it('writes one llm_tokens row + one web_tools row per call', async () => {
    const { supa, recorded } = mockSupa();
    await settleAuditUsage(
      supa,
      { kind: 'user', userId: 'u1' },
      {
        llmCostUsd: 0.01,
        modelId: 'gpt-5',
        llmProvider: 'openai',
        inputTokens: 100,
        outputTokens: 50,
        webTools: [
          { provider: 'exa', kind: 'search', costUsd: 0.005, status: 'success' },
          { provider: 'tavily', kind: 'scrape', costUsd: 0.0, status: 'error' },
        ],
        conversationId: 'c1',
        auditLogId: 'a1',
      },
    );
    const ueInserts = recorded.filter((r) => r.table === 'usage_events');
    expect(ueInserts).toHaveLength(3);
    const cats = ueInserts.map(
      (r) => (r.payload as { event_category: string }).event_category,
    );
    expect(cats).toEqual(['llm_tokens', 'web_tools', 'web_tools']);
    // LLM row sums all token counts into `quantity` (so audit can derive
    // tokens/$ later without re-walking raw_usage).
    expect((ueInserts[0].payload as { quantity: number }).quantity).toBe(150);
    // Failed web-tool call records cost 0 (matches v1 web-meter semantics).
    expect((ueInserts[2].payload as { vendor_cost_usd: number }).vendor_cost_usd).toBe(0);
  });

  it('skips llm row when cost is 0 / null', async () => {
    const { supa, recorded } = mockSupa();
    await settleAuditUsage(
      supa,
      { kind: 'user', userId: 'u1' },
      { llmCostUsd: 0 },
    );
    expect(recorded.filter((r) => r.table === 'usage_events')).toHaveLength(0);
  });

  it('writes subject-owner rows when owner kind is subject', async () => {
    const { supa, recorded } = mockSupa();
    await settleAuditUsage(
      supa,
      { kind: 'subject', subjectId: 's1' },
      { llmCostUsd: 0.001, llmProvider: 'anthropic', modelId: 'claude-sonnet-4-6' },
    );
    const ue = recorded.find((r) => r.table === 'usage_events');
    const payload = ue?.payload as { owner_user_id: unknown; owner_subject_id: unknown };
    expect(payload.owner_user_id).toBeNull();
    expect(payload.owner_subject_id).toBe('s1');
  });
});

describe('settleUsage', () => {
  // Focused mock: tracks the pack inventory, ledger insertions, and the
  // sequence of pack updates. Just enough surface to exercise the FIFO
  // walk, the CAS UPDATE, the running-balance computation, and the
  // overdraft fallback. Does NOT model concurrency (no two-process race
  // here); the CAS-loss branch is covered by setting a flag.
  interface MockPack {
    id: string;
    remaining_pnc_micros: number;
    status: 'active' | 'exhausted' | 'expired' | 'refunded';
    // optional: when set, the next UPDATE attempt returns null (CAS lost).
    casLossOnce?: boolean;
  }
  interface MockState {
    packs: MockPack[];
    ledger: Array<{
      entry_type: string;
      pack_id: string | null;
      delta_pnc_micros: number;
      balance_after_pnc_micros: number;
    }>;
    usageEvents: Array<Record<string, unknown>>;
    failUsageEventInsert?: boolean;
  }

  function buildSupa(state: MockState): SupabaseClient {
    let nextUsageId = 1;
    function fromPacks() {
      const predicates: Array<[string, unknown]> = [];
      const api = {
        select(_cols: string) {
          return api;
        },
        eq(col: string, val: unknown) {
          predicates.push([col, val]);
          return api;
        },
        order() {
          return api;
        },
        async limit(_n: number) {
          // FIFO read: return active packs for this owner.
          const owner = predicates.find(
            ([c]) => c === 'owner_user_id' || c === 'owner_subject_id',
          );
          if (!owner) return { data: [], error: null };
          return {
            data: state.packs
              .filter((p) => p.status === 'active')
              .map((p) => ({ id: p.id, remaining_pnc_micros: p.remaining_pnc_micros })),
            error: null,
          };
        },
        // The plain SUM-balance read uses select.eq.eq with no order/limit;
        // the test harness here resolves it via `then`.
        async then(resolve: (r: { data: unknown; error: null }) => void) {
          resolve({
            data: state.packs
              .filter((p) => p.status === 'active')
              .map((p) => ({ remaining_pnc_micros: p.remaining_pnc_micros })),
            error: null,
          });
        },
        update(values: Record<string, unknown>) {
          const updPredicates: Array<[string, unknown]> = [];
          const updApi = {
            eq(col: string, val: unknown) {
              updPredicates.push([col, val]);
              return updApi;
            },
            gte(_col: string, _val: unknown) {
              return updApi;
            },
            select() {
              return updApi;
            },
            async maybeSingle() {
              const id = updPredicates.find(([c]) => c === 'id')?.[1] as string | undefined;
              const pack = state.packs.find((p) => p.id === id);
              if (!pack) return { data: null, error: null };
              if (pack.casLossOnce) {
                pack.casLossOnce = false;
                return { data: null, error: null };
              }
              pack.remaining_pnc_micros = Number(values.remaining_pnc_micros);
              if (values.status === 'exhausted') pack.status = 'exhausted';
              return { data: { id }, error: null };
            },
          };
          return updApi;
        },
      };
      return api;
    }

    function fromUsageEvents() {
      return {
        insert(payload: Record<string, unknown>) {
          return {
            select() {
              return {
                async single() {
                  if (state.failUsageEventInsert) {
                    return { data: null, error: { message: 'mocked failure' } };
                  }
                  const id = `ue-${nextUsageId++}`;
                  state.usageEvents.push({ id, ...payload });
                  return { data: { id }, error: null };
                },
              };
            },
          };
        },
      };
    }

    function fromLedger() {
      return {
        async insert(payload: Record<string, unknown>) {
          state.ledger.push({
            entry_type: payload.entry_type as string,
            pack_id: (payload.pack_id as string | null) ?? null,
            delta_pnc_micros: Number(payload.delta_pnc_micros),
            balance_after_pnc_micros: Number(payload.balance_after_pnc_micros),
          });
          return { error: null };
        },
      };
    }

    function fromGroupPools() {
      return {
        select() {
          return {
            eq() {
              return {
                async maybeSingle() {
                  return { data: null, error: null };
                },
              };
            },
          };
        },
        async insert() {
          return { error: null };
        },
      };
    }

    return {
      from(table: string) {
        if (table === 'packs') return fromPacks() as never;
        if (table === 'usage_events') return fromUsageEvents() as never;
        if (table === 'ledger_entries') return fromLedger() as never;
        if (table === 'group_pools') return fromGroupPools() as never;
        throw new Error(`unexpected table ${table}`);
      },
    } as unknown as SupabaseClient;
  }

  it('FIFO-debits a single pack and writes one debit ledger row', async () => {
    const state: MockState = {
      packs: [
        // 100 PNC available; cost is 1 USD = 27 PNC = 27_000_000 micros.
        { id: 'p1', remaining_pnc_micros: 100 * PNC_MICROS_PER_PNC, status: 'active' },
      ],
      ledger: [],
      usageEvents: [],
    };
    const supa = buildSupa(state);
    const res = await settleUsage(supa, {
      owner: { kind: 'user', userId: 'u1' },
      category: 'llm_tokens',
      provider: 'openai',
      quantity: 1000,
      quantityUnit: 'tokens',
      vendorCostUsd: 1,
      costSource: 'gateway',
    });
    expect(res.pncMicrosBilled).toBe(27_000_000);
    expect(res.pncMicrosOverdrawn).toBe(0);
    expect(res.balanceAfterMicros).toBe(100 * PNC_MICROS_PER_PNC - 27_000_000);
    expect(res.thresholdState).toBe('sufficient');
    expect(state.packs[0].remaining_pnc_micros).toBe(100 * PNC_MICROS_PER_PNC - 27_000_000);
    expect(state.ledger).toHaveLength(1);
    expect(state.ledger[0]).toMatchObject({
      entry_type: 'debit',
      pack_id: 'p1',
      delta_pnc_micros: -27_000_000,
    });
  });

  it('splits a debit across two packs in FIFO order and flips the drained one to exhausted', async () => {
    const state: MockState = {
      packs: [
        { id: 'p1', remaining_pnc_micros: 10_000_000, status: 'active' }, // 10 PNC
        { id: 'p2', remaining_pnc_micros: 50_000_000, status: 'active' }, // 50 PNC
      ],
      ledger: [],
      usageEvents: [],
    };
    const supa = buildSupa(state);
    const res = await settleUsage(supa, {
      owner: { kind: 'user', userId: 'u1' },
      category: 'llm_tokens',
      provider: 'openai',
      quantity: 100,
      quantityUnit: 'tokens',
      vendorCostUsd: 1, // 27 PNC; eats p1 (10) then 17 from p2.
      costSource: 'gateway',
    });
    expect(res.pncMicrosBilled).toBe(27_000_000);
    expect(res.pncMicrosOverdrawn).toBe(0);
    expect(state.packs[0].remaining_pnc_micros).toBe(0);
    expect(state.packs[0].status).toBe('exhausted');
    expect(state.packs[1].remaining_pnc_micros).toBe(50_000_000 - 17_000_000);
    expect(state.ledger).toHaveLength(2);
    expect(state.ledger[0]).toMatchObject({ pack_id: 'p1', delta_pnc_micros: -10_000_000 });
    expect(state.ledger[1]).toMatchObject({ pack_id: 'p2', delta_pnc_micros: -17_000_000 });
    // Running balance after each debit matches a running tally from the
    // initial total of 60 PNC = 60_000_000 micros.
    expect(state.ledger[0].balance_after_pnc_micros).toBe(60_000_000 - 10_000_000);
    expect(state.ledger[1].balance_after_pnc_micros).toBe(60_000_000 - 27_000_000);
  });

  it('writes an overdraft ledger row when packs are exhausted (no pack_id)', async () => {
    const state: MockState = {
      packs: [
        { id: 'p1', remaining_pnc_micros: 5_000_000, status: 'active' }, // 5 PNC
      ],
      ledger: [],
      usageEvents: [],
    };
    const supa = buildSupa(state);
    const res = await settleUsage(supa, {
      owner: { kind: 'user', userId: 'u1' },
      category: 'llm_tokens',
      provider: 'openai',
      quantity: 100,
      quantityUnit: 'tokens',
      vendorCostUsd: 1, // 27 PNC owed but only 5 PNC available → 22 PNC overdraft
      costSource: 'gateway',
    });
    expect(res.pncMicrosBilled).toBe(5_000_000);
    expect(res.pncMicrosOverdrawn).toBe(22_000_000);
    expect(res.balanceAfterMicros).toBe(-22_000_000);
    // exhausted threshold band (≤ 0).
    expect(res.thresholdState).toBe('exhausted');
    expect(state.ledger).toHaveLength(2);
    expect(state.ledger[0]).toMatchObject({ entry_type: 'debit', pack_id: 'p1' });
    expect(state.ledger[1]).toMatchObject({
      entry_type: 'overdraft',
      pack_id: null,
      delta_pnc_micros: -22_000_000,
    });
  });

  it('writes a single overdraft row when the owner has zero packs', async () => {
    const state: MockState = { packs: [], ledger: [], usageEvents: [] };
    const supa = buildSupa(state);
    const res = await settleUsage(supa, {
      owner: { kind: 'user', userId: 'u1' },
      category: 'web_tools',
      provider: 'exa',
      vendorSku: 'exa:search',
      quantity: 1,
      quantityUnit: 'calls',
      vendorCostUsd: 0.005, // ~135_000 micros
      costSource: 'local_pricebook',
    });
    expect(res.pncMicrosBilled).toBe(0);
    expect(res.pncMicrosOverdrawn).toBe(135_000);
    expect(state.ledger).toHaveLength(1);
    expect(state.ledger[0]).toMatchObject({
      entry_type: 'overdraft',
      pack_id: null,
    });
  });

  it('retries once after a CAS loss, succeeds on second attempt', async () => {
    const state: MockState = {
      packs: [
        { id: 'p1', remaining_pnc_micros: 100_000_000, status: 'active', casLossOnce: true },
      ],
      ledger: [],
      usageEvents: [],
    };
    const supa = buildSupa(state);
    const res = await settleUsage(supa, {
      owner: { kind: 'user', userId: 'u1' },
      category: 'llm_tokens',
      provider: 'openai',
      quantity: 50,
      quantityUnit: 'tokens',
      vendorCostUsd: 0.5, // 13_500_000 micros
      costSource: 'gateway',
    });
    expect(res.pncMicrosBilled).toBe(13_500_000);
    expect(res.pncMicrosOverdrawn).toBe(0);
    expect(state.packs[0].remaining_pnc_micros).toBe(100_000_000 - 13_500_000);
    expect(state.ledger).toHaveLength(1);
  });

  it('zero-cost event still inserts usage_event, no ledger debit', async () => {
    const state: MockState = {
      packs: [
        { id: 'p1', remaining_pnc_micros: 50_000_000, status: 'active' },
      ],
      ledger: [],
      usageEvents: [],
    };
    const supa = buildSupa(state);
    const res = await settleUsage(supa, {
      owner: { kind: 'user', userId: 'u1' },
      category: 'web_tools',
      provider: 'exa',
      quantity: 1,
      quantityUnit: 'calls',
      vendorCostUsd: 0, // failed call, audit-only
      costSource: 'local_pricebook',
    });
    expect(res.pncMicrosBilled).toBe(0);
    expect(res.pncMicrosOverdrawn).toBe(0);
    expect(state.usageEvents).toHaveLength(1);
    expect(state.ledger).toHaveLength(0);
    // Pack untouched.
    expect(state.packs[0].remaining_pnc_micros).toBe(50_000_000);
  });

  it('soft-fails when usage_events insert fails (no throw, no ledger)', async () => {
    const state: MockState = {
      packs: [
        { id: 'p1', remaining_pnc_micros: 100_000_000, status: 'active' },
      ],
      ledger: [],
      usageEvents: [],
      failUsageEventInsert: true,
    };
    const supa = buildSupa(state);
    const res = await settleUsage(supa, {
      owner: { kind: 'user', userId: 'u1' },
      category: 'llm_tokens',
      provider: 'openai',
      quantity: 100,
      quantityUnit: 'tokens',
      vendorCostUsd: 1,
      costSource: 'gateway',
    });
    expect(res.usageEventId).toBe('');
    expect(res.pncMicrosBilled).toBe(0);
    expect(res.pncMicrosOverdrawn).toBe(0);
    // Balance read still works → returns the unchanged 100 PNC.
    expect(res.balanceAfterMicros).toBe(100_000_000);
    expect(state.ledger).toHaveLength(0);
    expect(state.packs[0].remaining_pnc_micros).toBe(100_000_000);
  });

  it('routes subject-owner packs through subject column', async () => {
    const state: MockState = {
      packs: [
        { id: 'gp1', remaining_pnc_micros: 100_000_000, status: 'active' },
      ],
      ledger: [],
      usageEvents: [],
    };
    const supa = buildSupa(state);
    const res = await settleUsage(supa, {
      owner: { kind: 'subject', subjectId: 's1' },
      category: 'llm_tokens',
      provider: 'openai',
      quantity: 100,
      quantityUnit: 'tokens',
      vendorCostUsd: 1,
      costSource: 'gateway',
    });
    expect(res.pncMicrosBilled).toBe(27_000_000);
    // usage_events row carries the subject owner.
    const ue = state.usageEvents[0];
    expect(ue.owner_user_id).toBeNull();
    expect(ue.owner_subject_id).toBe('s1');
  });
});

describe('defaultPackExpiresAt', () => {
  it('adds 365 days (UTC) — §4', () => {
    const now = new Date('2026-05-29T10:00:00Z');
    const expiresAt = defaultPackExpiresAt(now);
    const expires = new Date(expiresAt);
    const diffMs = expires.getTime() - now.getTime();
    // 365 days = 365 * 86_400_000 ms = 31_536_000_000
    expect(diffMs).toBe(365 * 86_400_000);
  });

  it('returns an ISO string', () => {
    const out = defaultPackExpiresAt(new Date('2026-01-01T00:00:00Z'));
    expect(out).toMatch(/^\d{4}-\d{2}-\d{2}T/);
    expect(() => new Date(out)).not.toThrow();
  });
});
