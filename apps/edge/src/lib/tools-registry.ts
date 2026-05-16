import { serviceClient, type SupabaseClient } from './supabase';
import { kvConfig } from './kv-config';
import type { Env } from '../types';

// Tools-registry cache — the runtime side of pendingbot.tools. Edge
// reads the table on a 60s isolate TTL and filters its assembled tool
// list against the result before handing to the model. Disabling a
// row in the board page is the kill-switch that takes effect within
// a minute, no deploy needed.
//
// Two scopes: 'chat' for bot-reply, 'envelope' for envelope-runner.
// A tool can live on either or both — the column is JSON so a single
// row covers both surfaces.

export type ToolScope = 'chat' | 'envelope';

interface ToolRow {
  key: string;
  scopes: string[];
}

const REGISTRY_TTL_MS = 60_000;
const REGISTRY_TTL_S = REGISTRY_TTL_MS / 1000;
let cache: { at: number; rows: ToolRow[] } | null = null;

async function loadRows(env: Env): Promise<ToolRow[] | null> {
  const now = Date.now();
  if (cache && now - cache.at < REGISTRY_TTL_MS) return cache.rows;
  let rows: ToolRow[];
  try {
    // KV read-through (shared L2) in front of the isolate Map. The
    // loader throws on a DB error so the failure is NOT cached — that
    // keeps the fail-open behaviour below.
    rows = await kvConfig(env, 'cfg:tools-registry', REGISTRY_TTL_S, async () => {
      const supa: SupabaseClient = serviceClient(env);
      const { data, error } = await supa
        .from('tools')
        .select('key, scopes')
        .eq('enabled', true);
      if (error || !data) throw new Error(error?.message ?? 'no data');
      return data.map<ToolRow>((r) => ({
        key: r.key,
        scopes: Array.isArray(r.scopes)
          ? (r.scopes as unknown[]).filter((s): s is string => typeof s === 'string')
          : [],
      }));
    });
  } catch (err) {
    // Fail-open: callers receive `null` and skip filtering. A flaky
    // DB connection should not silently strip every tool from the
    // model — that's worse than the kill-switch being slow.
    console.warn('[tools-registry] load failed:', err instanceof Error ? err.message : String(err));
    return null;
  }
  cache = { at: now, rows };
  return rows;
}

/**
 * Returns the set of tool keys that are enabled AND tagged with the
 * given scope. `null` means "registry unreachable, do not filter" so
 * the caller passes through its original tool list unchanged.
 */
export async function loadAllowedTools(
  env: Env,
  scope: ToolScope,
): Promise<Set<string> | null> {
  const rows = await loadRows(env);
  if (rows === null) return null;
  const out = new Set<string>();
  for (const r of rows) if (r.scopes.includes(scope)) out.add(r.key);
  return out;
}
