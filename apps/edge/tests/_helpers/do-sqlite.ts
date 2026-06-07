// node:sqlite-backed DurableObjectState shim for unit-testing SQLite DOs.
//
// The projection DOs (ConvProjectionDO / UserProjectionDO) talk to workerd's
// `ctx.storage.sql.exec(...)`. The repo's vitest runs in plain Node (no workerd
// globals), so we can't instantiate those DOs directly the way the route tests
// avoid. Instead we back `storage.sql` with Node's built-in `node:sqlite`
// (`DatabaseSync`), which speaks the same SQLite dialect — so the DO's *real*
// SQL runs against a real in-memory engine. This exercises the actual upsert /
// ON CONFLICT / tombstone / trim / delta queries, not a JS re-implementation.
//
// Faithfulness to workerd's SqlStorageCursor that the DOs depend on:
//   - exec(sql, ...bindings) runs immediately and returns a cursor.
//   - cursor.toArray() → all rows; cursor.one() → the single row (throws if
//     the row count isn't exactly 1, matching workerd).
//   - exec() with no bindings may carry multiple statements (the CREATE block
//     in the DO constructor) → routed through DatabaseSync.exec which runs all.
//   - exec() with bindings is always a single statement → prepare(...).all(...).
//
// `node:sqlite` has no @types/node in this package, and verbatimModuleSyntax +
// strict are on, so we declare the slice of the module surface we use. We load
// it via `process.getBuiltinModule('node:sqlite')` rather than a static import:
// Vite (vitest's transformer) would otherwise try to bundle the `node:sqlite`
// specifier and fail to resolve it. getBuiltinModule takes a runtime string, so
// Vite never sees a module to pre-bundle.

type SqlValue = string | number | bigint | null | Uint8Array;

interface NodePreparedStatement {
  // .all() runs the statement and returns result rows ([] for non-SELECT),
  // which covers every shape the projection DOs issue (SELECT / INSERT /
  // UPDATE / DELETE / upsert).
  all(...params: SqlValue[]): Array<Record<string, SqlValue>>;
}
interface NodeDatabase {
  exec(sql: string): void;
  prepare(sql: string): NodePreparedStatement;
}
interface NodeDatabaseCtor {
  new (path: string): NodeDatabase;
}

// process.getBuiltinModule (Node ≥ 22.3) — typed locally; @types/node absent.
const getBuiltinModule = (
  globalThis as unknown as {
    process: { getBuiltinModule(id: string): { DatabaseSync: NodeDatabaseCtor } };
  }
).process.getBuiltinModule;

const Database: NodeDatabaseCtor = getBuiltinModule('node:sqlite').DatabaseSync;

/** Normalize node:sqlite output (bigint counts) into the number-ish rows the DOs expect. */
function normalizeRow(row: Record<string, SqlValue>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(row)) {
    out[k] = typeof v === 'bigint' ? Number(v) : v;
  }
  return out;
}

/** Minimal stand-in for workerd's SqlStorageCursor (only what the DOs touch). */
class FakeCursor<T> {
  constructor(private readonly rows: T[]) {}
  toArray(): T[] {
    return this.rows;
  }
  one(): T {
    if (this.rows.length !== 1) {
      throw new Error(`SqlStorageCursor.one(): expected exactly 1 row, got ${this.rows.length}`);
    }
    return this.rows[0]!;
  }
}

class FakeSqlStorage {
  constructor(private readonly db: NodeDatabase) {}

  exec<T = Record<string, unknown>>(query: string, ...bindings: unknown[]): FakeCursor<T> {
    if (bindings.length === 0) {
      // No params → may be a multi-statement DDL block (the CREATE in the ctor)
      // or a single bare statement. DatabaseSync.exec runs every statement but
      // returns nothing, so for read-back we still try prepare when it's a
      // single statement. Heuristic: if it has a trailing SELECT we re-run via
      // prepare to get rows; otherwise exec it.
      const trimmed = query.trim();
      const isMulti = trimmed.replace(/;\s*$/, '').includes(';');
      if (isMulti) {
        this.db.exec(query);
        return new FakeCursor<T>([]);
      }
      const rows = this.db.prepare(query).all().map(normalizeRow);
      return new FakeCursor<T>(rows as T[]);
    }
    const params = bindings.map((b) => (b === undefined ? null : (b as SqlValue)));
    const rows = this.db.prepare(query).all(...params).map(normalizeRow);
    return new FakeCursor<T>(rows as T[]);
  }
}

/** A fake DurableObjectId carrying just the `.name` the DOs read. */
class FakeDurableObjectId {
  constructor(public readonly name: string) {}
  equals(): boolean {
    return false;
  }
  toString(): string {
    return this.name;
  }
}

/**
 * Build a DurableObjectState shim backed by a fresh in-memory SQLite db.
 * `name` becomes `state.id.name` (the DOs use it as conversation_id / user_id
 * for backfill). Cast through unknown — we only implement the slice the
 * projection DOs use (id.name, storage.sql.exec, blockConcurrencyWhile).
 */
export function makeSqliteDoState(name: string): DurableObjectState {
  const db = new Database(':memory:');
  const sql = new FakeSqlStorage(db);
  const state = {
    id: new FakeDurableObjectId(name),
    storage: { sql },
    blockConcurrencyWhile<T>(cb: () => Promise<T>): Promise<T> {
      // Run synchronously-ish; the ctor body is sync SQL wrapped in async.
      return cb();
    },
    waitUntil(): void {
      /* no-op */
    },
  };
  return state as unknown as DurableObjectState;
}
