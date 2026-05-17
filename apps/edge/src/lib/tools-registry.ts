import type { ChatCompletionTool } from 'openai/resources/chat/completions';
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
//
// The registry also carries `model_description`: the board-editable
// description the model actually sees. For native tools it's the single
// source of truth — the edge tool defs (tool-defs.ts, envelope-loop.ts)
// carry no `function.description` at all, so the registry value is
// swapped in at turn-assembly time. For MCP tools it's optional: NULL
// means use the upstream MCP server's own description.

export type ToolScope = 'chat' | 'envelope';

interface ToolRow {
  key: string;
  scopes: string[];
  modelDescription: string | null;
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
        .select('key, scopes, model_description')
        .eq('enabled', true);
      if (error || !data) throw new Error(error?.message ?? 'no data');
      return data.map<ToolRow>((r) => ({
        key: r.key,
        scopes: Array.isArray(r.scopes)
          ? (r.scopes as unknown[]).filter((s): s is string => typeof s === 'string')
          : [],
        modelDescription:
          typeof r.model_description === 'string' && r.model_description.trim()
            ? r.model_description
            : null,
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
 * A resolved view of the registry for one scope: the set of tool keys
 * the model is allowed to see, each mapped to its `model_description`
 * (`null` = keep the tool's own description, used for MCP tools that
 * defer to the upstream server).
 */
export interface ToolRegistryView {
  allowed: Map<string, string | null>;
}

/**
 * Loads the registry for a scope. `null` means "registry unreachable,
 * do not filter" so the caller passes through its original tool list
 * unchanged (see applyToolRegistry). Safe to call early and await
 * later — `loadRows` is cached on a 60s isolate TTL.
 */
export async function loadToolRegistry(
  env: Env,
  scope: ToolScope,
): Promise<ToolRegistryView | null> {
  const rows = await loadRows(env);
  if (rows === null) return null;
  const allowed = new Map<string, string | null>();
  for (const r of rows) {
    if (r.scopes.includes(scope)) allowed.set(r.key, r.modelDescription);
  }
  return { allowed };
}

/**
 * Filters `tools` to the registry's allowlist and swaps in each tool's
 * `model_description`. Native tools always carry one (DB CHECK enforces
 * it); MCP tools may be `null`, in which case the upstream description
 * is kept. `registry === null` (registry unreachable) passes the list
 * through untouched — fail-open.
 */
export function applyToolRegistry(
  tools: ChatCompletionTool[],
  registry: ToolRegistryView | null,
): ChatCompletionTool[] {
  if (registry === null) return tools;
  const out: ChatCompletionTool[] = [];
  for (const t of tools) {
    if (!registry.allowed.has(t.function.name)) continue;
    const override = registry.allowed.get(t.function.name);
    out.push(
      override
        ? { ...t, function: { ...t.function, description: override } }
        : t,
    );
  }
  return out;
}
