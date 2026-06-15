// Minimal in-memory supabase-js mock — enough surface to exercise the
// routes that hit `serviceClient(env).schema('pendingbot').from(...)`.
//
// Supports the chain shapes our code actually uses:
//
//   .schema(name)
//   .from(table)
//   .select(cols, { count?, head? })
//   .eq(col, val) / .neq(col, val) / .in(col, vals) / .is(col, val)
//   .filter(jsonbPath, 'cs', JSON.stringify([id]))   — jsonb array contains
//   .update(patch) / .delete() / .insert(row) / .upsert(row, opts?)
//   .maybeSingle() / .single() / await (then)
//
// Not a real Postgres — every query is a JS filter over an in-memory
// row array. Good enough to pin route contracts; if a test starts
// needing FK cascades or RLS this helper is the wrong tool.

import { vi } from 'vitest';
import type { Env } from '../../src/types';

export type Row = Record<string, unknown>;

export interface FakeDb {
  rows: Record<string, Row[]>;
  inserts: Array<{ table: string; row: Row }>;
  updates: Array<{ table: string; patch: Row; filters: Filter[] }>;
  deletes: Array<{ table: string; filters: Filter[]; count: number }>;
  rpcs?: Record<string, (args: Record<string, unknown>) => { data?: unknown; error?: { code?: string; message: string } | null }>;
  auth?: {
    users?: Record<string, { email?: string | null }>;
    generatedLinks?: Array<{ type: string; email: string }>;
    generateLinkError?: { message: string } | null;
  };
  /// Optional per-table error injection. When a function returns
  /// non-null for a given operation, that error replaces the result.
  errors?: {
    select?: (table: string) => { code?: string; message: string } | null;
    insert?: (table: string, row: Row) => { code?: string; message: string } | null;
    update?: (table: string) => { code?: string; message: string } | null;
    delete?: (table: string) => { code?: string; message: string } | null;
  };
}

interface Filter {
  kind: 'eq' | 'neq' | 'in' | 'is' | 'jsonb_cs' | 'or';
  col: string;
  value: unknown;
}

/** One disjunct of a PostgREST `.or(...)` expression. */
interface OrTerm {
  col: string;
  op: 'is' | 'eq' | 'neq';
  value: unknown;
}

export function makeFakeDb(seed: Record<string, Row[]> = {}): FakeDb {
  return {
    rows: Object.fromEntries(Object.entries(seed).map(([t, rs]) => [t, [...rs]])),
    inserts: [],
    updates: [],
    deletes: [],
  };
}

/// A WalletDO call captured by the fake env's WALLET binding. `path` is
/// the RPC verb (gate / debit / credit / apply-absolute); `body` is the
/// JSON the wallet-client posted (subjectId + pncMicros + category + …).
export interface WalletCall {
  subjectId: string;
  path: string;
  body: Record<string, unknown>;
}

export interface FakeWallet {
  calls: WalletCall[];
  /// Per-subject balance the fake gate/debit replies with (micros). Seed
  /// before the test to drive threshold branching; debit decrements it.
  balances: Record<string, number>;
}

/// Minimal in-memory KV backing the `MEMORY` binding. `store` holds the
/// JSON values; `get(key, 'json')` returns the stored object, `put(key, val)`
/// JSON-parses and stores. `throws` makes both ops reject (to exercise the
/// KV-failure fallback path). Tests can seed `store` and inspect it after.
export interface FakeKv {
  store: Record<string, unknown>;
  throws: boolean;
}

export function makeFakeEnv(
  db: FakeDb,
  opts?: { wallet?: FakeWallet; kv?: FakeKv },
): Env {
  const fakeWallet: FakeWallet = opts?.wallet ?? { calls: [], balances: {} };
  const fakeKv: FakeKv = opts?.kv ?? { store: {}, throws: false };
  const memoryBinding = {
    get: async (key: string, _type?: string) => {
      if (fakeKv.throws) throw new Error('kv down');
      return fakeKv.store[key] ?? null;
    },
    put: async (key: string, value: string) => {
      if (fakeKv.throws) throw new Error('kv down');
      fakeKv.store[key] = typeof value === 'string' ? JSON.parse(value) : value;
    },
    delete: async (key: string) => {
      delete fakeKv.store[key];
    },
  };
  const walletBinding = {
    idFromName: (name: string) => name,
    get: (subjectId: string) => ({
      fetch: async (url: string | URL, init?: { body?: string }) => {
        const path = new URL(String(url)).pathname;
        const body = init?.body
          ? (JSON.parse(init.body) as Record<string, unknown>)
          : {};
        fakeWallet.calls.push({ subjectId, path, body });
        const cur = fakeWallet.balances[subjectId] ?? 0;
        let next = cur;
        if (path === '/debit') next = cur - Number(body.pncMicros ?? 0);
        else if (path === '/credit') next = cur + Number(body.pncMicros ?? 0);
        fakeWallet.balances[subjectId] = next;
        // Mirror WalletDO.thresholdOf: ≥50 PNC sufficient / ≥5 low / >0 throttle / ≤0 exhausted.
        const thresholdState =
          next >= 50_000_000 ? 'sufficient' : next >= 5_000_000 ? 'low' : next > 0 ? 'throttle' : 'exhausted';
        return new Response(
          JSON.stringify({ balanceMicros: next, thresholdState }),
          { headers: { 'content-type': 'application/json' } },
        );
      },
    }),
  };
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const env: any = {
    SUPABASE_URL: 'https://example.supabase.co',
    SUPABASE_SECRET_KEY: 'service-key',
    // Billing tests exercise the live gate/debit path — enable the kill-switch.
    BILLING_ENABLED: 'true',
    WALLET: walletBinding,
    MEMORY: memoryBinding,
    __fakeDb: db,
    __fakeWallet: fakeWallet,
    __fakeKv: fakeKv,
  };
  return env as Env;
}

/**
 * Apply the `vi.mock('../lib/supabase', ...)` factory that routes the
 * `serviceClient` / `userClient` factories into the fake DB carried on
 * the env object. Call once per test file (top-level).
 */
export function installFakeSupabaseMock() {
  vi.mock('../../src/lib/supabase', () => ({
    serviceClient: (env: Env) => makeClient((env as unknown as { __fakeDb: FakeDb }).__fakeDb),
    userClient: (env: Env) => makeClient((env as unknown as { __fakeDb: FakeDb }).__fakeDb),
  }));
}

function rowsForFilters(rows: Row[], filters: Filter[]): Row[] {
  return rows.filter((r) => filters.every((f) => matches(r, f)));
}

function matches(row: Row, f: Filter): boolean {
  switch (f.kind) {
    case 'eq':
      return row[f.col] === f.value;
    case 'neq':
      return row[f.col] !== f.value;
    case 'in':
      return Array.isArray(f.value) && (f.value as unknown[]).includes(row[f.col]);
    case 'is':
      return row[f.col] === f.value; // only null in practice
    case 'jsonb_cs': {
      // .filter('attachments->ids', 'cs', JSON.stringify([id]))
      // → the row's `attachments.ids` array contains every element in `needles`.
      const [topCol, sub] = f.col.split('->');
      const top = row[topCol] as { [k: string]: unknown } | null | undefined;
      if (!top) return false;
      const arr = top[sub];
      if (!Array.isArray(arr)) return false;
      let needles: unknown[] = [];
      try {
        needles = JSON.parse(f.value as string);
      } catch {
        return false;
      }
      return needles.every((n) => (arr as unknown[]).includes(n));
    }
    case 'or': {
      const terms = f.value as OrTerm[];
      return terms.some((t) => {
        const actual = readPath(row, t.col);
        if (t.op === 'is') return actual === t.value; // only null in practice
        if (t.op === 'neq') return actual !== t.value;
        return actual === t.value;
      });
    }
  }
}

/** Read a plain column or a PostgREST `a->>b` jsonb path off a row. */
function readPath(row: Row, col: string): unknown {
  if (col.includes('->>')) {
    const [top, sub] = col.split('->>');
    const obj = row[top] as Record<string, unknown> | null | undefined;
    return obj == null ? null : obj[sub];
  }
  return row[col];
}

/** 直接拿一个绑定到 db 的 fake supabase client(供直接收 `supa` 参数的单元用)。 */
export function makeFakeClient(db: FakeDb): SupabaseClientLike {
  return makeClient(db) as SupabaseClientLike;
}

// 最小 client 形状(只声明我们用到的;实参在 makeClient 里全实现)。
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type SupabaseClientLike = any;

function makeClient(db: FakeDb): unknown {
  const builder = (table: string) => {
    const filters: Filter[] = [];
    let mode: 'select' | 'update' | 'delete' | 'insert' | 'upsert' = 'select';
    let cols = '*';
    let selectOpts: { count?: 'exact'; head?: boolean } | undefined;
    let patch: Row | null = null;
    let insertRow: Row | null = null;
    let insertError: { code?: string; message: string } | null = null;
    let orderBy: { col: string; ascending: boolean } | null = null;
    let limitCount: number | null = null;
    let rangeFrom: number | null = null;
    let rangeTo: number | null = null;

    const api = {
      select(c: string = '*', opts?: { count?: 'exact'; head?: boolean }) {
        cols = c;
        selectOpts = opts;
        return api;
      },
      eq(col: string, value: unknown) {
        filters.push({ kind: 'eq', col, value });
        return api;
      },
      neq(col: string, value: unknown) {
        filters.push({ kind: 'neq', col, value });
        return api;
      },
      in(col: string, values: unknown[]) {
        filters.push({ kind: 'in', col, value: values });
        return api;
      },
      is(col: string, value: unknown) {
        filters.push({ kind: 'is', col, value });
        return api;
      },
      filter(col: string, op: string, value: unknown) {
        if (op === 'cs') {
          filters.push({ kind: 'jsonb_cs', col, value });
        } else {
          throw new Error(`fake-supabase: unsupported .filter op "${op}"`);
        }
        return api;
      },
      // PostgREST .or('a.is.null,b->>c.neq.x') — keep rows where ANY disjunct
      // holds. We parse the small subset our code emits (is.null / eq.X /
      // neq.X over a plain col or an `a->>b` jsonb path).
      or(expr: string) {
        const terms: OrTerm[] = expr.split(',').map((part) => {
          const [col, op, ...rest] = part.split('.');
          const raw = rest.join('.');
          if (op === 'is') return { col, op: 'is', value: raw === 'null' ? null : raw };
          if (op === 'neq') return { col, op: 'neq', value: raw };
          return { col, op: 'eq', value: raw };
        });
        filters.push({ kind: 'or', col: '', value: terms });
        return api;
      },
      order(col: string, opts?: { ascending?: boolean }) {
        orderBy = { col, ascending: opts?.ascending !== false };
        return api;
      },
      limit(n: number) {
        limitCount = n;
        return api;
      },
      range(from: number, to: number) {
        rangeFrom = from;
        rangeTo = to;
        return api;
      },
      update(p: Row) {
        mode = 'update';
        patch = p;
        return api;
      },
      delete() {
        mode = 'delete';
        return api;
      },
      insert(r: Row) {
        // supabase-js .insert returns a chainable filter builder — the
        // route can do `.insert(row).select(cols).single()`. We perform
        // the actual side effect here so the row is observable in db.rows
        // even when the caller doesn't await before reading.
        mode = 'insert';
        insertRow = r;
        const err = db.errors?.insert?.(table, r);
        if (!err) {
          const tableRows = (db.rows[table] ??= []);
          tableRows.push({ ...r });
          db.inserts.push({ table, row: { ...r } });
        }
        // Stash the error for terminal ops to surface.
        insertError = err ?? null;
        return api;
      },
      upsert(r: Row, opts?: { onConflict?: string; ignoreDuplicates?: boolean }) {
        mode = 'upsert';
        insertRow = r;
        const err = db.errors?.insert?.(table, r);
        if (!err) {
          const tableRows = (db.rows[table] ??= []);
          const conflictCol = opts?.onConflict;
          const existing = conflictCol
            ? tableRows.find((row) => row[conflictCol] === r[conflictCol])
            : undefined;
          if (existing) {
            if (!opts?.ignoreDuplicates) Object.assign(existing, r);
          } else {
            tableRows.push({ ...r });
            db.inserts.push({ table, row: { ...r } });
          }
        }
        insertError = err ?? null;
        return api;
      },
      async maybeSingle() {
        if (mode === 'insert') {
          if (insertError) return { data: null, error: insertError };
          return { data: insertRow ? { ...insertRow } : null, error: null };
        }
        const err = db.errors?.select?.(table);
        if (err) return { data: null, error: err };
        const rs = rowsForFilters(db.rows[table] ?? [], filters);
        return { data: rs[0] ? { ...rs[0] } : null, error: null };
      },
      async single() {
        if (mode === 'insert') {
          if (insertError) return { data: null, error: insertError };
          return { data: insertRow ? { ...insertRow } : null, error: null };
        }
        const err = db.errors?.select?.(table);
        if (err) return { data: null, error: err };
        const rs = rowsForFilters(db.rows[table] ?? [], filters);
        if (rs.length === 0) {
          return { data: null, error: { code: 'PGRST116', message: 'no rows' } };
        }
        return { data: { ...rs[0] }, error: null };
      },
      // .insert(...).select(...).single() — supabase-js chains this; we make
      // .insert resolve immediately above, but routes also do
      // .insert(row).select(cols).single() as a single awaited chain. To
      // support that we expose .then on the builder so it awaits as the
      // insert result with the seeded row.
      then(resolve: (v: unknown) => void, reject?: (e: unknown) => void) {
        // Terminal operations land here when the route does
        //   `const { error } = await supa.from(t).update(p).eq(...)` etc.
        const run = async () => {
          switch (mode) {
            case 'update': {
              const err = db.errors?.update?.(table);
              if (err) return { data: null, error: err };
              const tableRows = (db.rows[table] ??= []);
              const matched = rowsForFilters(tableRows, filters);
              for (const r of matched) {
                Object.assign(r, patch);
              }
              db.updates.push({ table, patch: patch as Row, filters: [...filters] });
              return { data: null, error: null };
            }
            case 'delete': {
              const err = db.errors?.delete?.(table);
              if (err) return { data: null, error: err };
              const tableRows = (db.rows[table] ??= []);
              const before = tableRows.length;
              const keep = tableRows.filter((r) => !filters.every((f) => matches(r, f)));
              db.rows[table] = keep;
              db.deletes.push({ table, filters: [...filters], count: before - keep.length });
              return { data: null, error: null };
            }
            case 'insert':
            case 'upsert': {
              if (insertError) return { data: null, error: insertError };
              return { data: insertRow ? { ...insertRow } : null, error: null };
            }
            case 'select': {
              const err = db.errors?.select?.(table);
              if (err) return { data: null, error: err };
              let rs = rowsForFilters(db.rows[table] ?? [], filters);
              if (orderBy) {
                rs = [...rs].sort((a, b) => {
                  const av = a[orderBy!.col];
                  const bv = b[orderBy!.col];
                  if (av === bv) return 0;
                  const cmp = String(av ?? '') < String(bv ?? '') ? -1 : 1;
                  return orderBy!.ascending ? cmp : -cmp;
                });
              }
              // count: 'exact' reports the total BEFORE pagination (supabase
              // semantics); .range()/.limit() then slice the returned page.
              const total = rs.length;
              if (rangeFrom != null) {
                rs = rs.slice(rangeFrom, (rangeTo ?? rs.length - 1) + 1);
              } else if (limitCount != null) {
                rs = rs.slice(0, limitCount);
              }
              const exactCount = rangeFrom != null ? total : rs.length;
              if (selectOpts?.count === 'exact' && selectOpts.head) {
                return { data: null, count: exactCount, error: null };
              }
              if (selectOpts?.count === 'exact') {
                return { data: rs.map((r) => ({ ...r })), count: exactCount, error: null };
              }
              return { data: rs.map((r) => ({ ...r })), error: null };
            }
          }
        };
        return run().then(resolve, reject);
      },
    } as const;

    return api;
  };

  return {
    auth: {
      admin: {
        getUserById: async (id: string) => {
          const user = db.auth?.users?.[id] ?? null;
          return { data: { user }, error: null };
        },
        generateLink: async (params: { type: string; email: string }) => {
          if (db.auth?.generateLinkError) {
            return { data: null, error: db.auth.generateLinkError };
          }
          db.auth ??= {};
          db.auth.generatedLinks ??= [];
          db.auth.generatedLinks.push(params);
          return {
            data: {
              properties: {
                hashed_token: `hash-for-${params.email}`,
              },
            },
            error: null,
          };
        },
      },
    },
    schema(_name: string) {
      // schema('pendingbot').from(...) just unwraps to the same builder.
      return { from: builder };
    },
    from: builder,
    async rpc(fn: string, args: Record<string, unknown>) {
      const handler = db.rpcs?.[fn];
      if (!handler) return { data: null, error: null };
      return handler(args);
    },
  };
}
