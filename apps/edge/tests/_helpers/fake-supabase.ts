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
  kind: 'eq' | 'neq' | 'in' | 'is' | 'jsonb_cs';
  col: string;
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

export function makeFakeEnv(db: FakeDb): Env {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const env: any = {
    SUPABASE_URL: 'https://example.supabase.co',
    SUPABASE_SERVICE_ROLE_KEY: 'service-key',
    __fakeDb: db,
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
  }
}

function makeClient(db: FakeDb): unknown {
  const builder = (table: string) => {
    const filters: Filter[] = [];
    let mode: 'select' | 'update' | 'delete' | 'insert' | 'upsert' = 'select';
    let cols = '*';
    let selectOpts: { count?: 'exact'; head?: boolean } | undefined;
    let patch: Row | null = null;
    let insertRow: Row | null = null;
    let insertError: { code?: string; message: string } | null = null;

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
              const rs = rowsForFilters(db.rows[table] ?? [], filters);
              if (selectOpts?.count === 'exact' && selectOpts.head) {
                return { data: null, count: rs.length, error: null };
              }
              if (selectOpts?.count === 'exact') {
                return { data: rs.map((r) => ({ ...r })), count: rs.length, error: null };
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
    schema(_name: string) {
      // schema('pendingbot').from(...) just unwraps to the same builder.
      return { from: builder };
    },
    from: builder,
  };
}
