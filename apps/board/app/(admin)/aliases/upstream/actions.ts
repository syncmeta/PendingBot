'use server';

import { headers } from 'next/headers';
import { revalidatePath } from 'next/cache';
import { requireAdmin } from '@/lib/auth';
import { supabaseAdmin } from '@/lib/supabase/admin';
import {
  buildUpstreamDiff,
  type AliasDiffRow,
} from '@/lib/upstream-prices';

// Two server actions back the /aliases/upstream page:
//
//   pullUpstreamPrices  — anonymous fetch to OpenRouter, plus mirror
//                         resolution for providers configured that way.
//                         Returns the full diff (no DB writes).
//   applyUpstreamPrices — takes the snapshot the user saw + a list of
//                         alias ids the user checked, writes them. We
//                         do NOT re-fetch upstream on apply, so the
//                         user gets exactly the values they confirmed.

export interface PullState {
  ok: boolean;
  fetchedAt?: string;
  rows?: AliasDiffRow[];
  error?: string;
}

export async function pullUpstreamPrices(
  _prev: PullState,
  _formData: FormData,
): Promise<PullState> {
  await requireAdmin();
  try {
    const supa = supabaseAdmin();
    const { rows, openRouterFetchedAt } = await buildUpstreamDiff(supa);
    return { ok: true, rows, fetchedAt: openRouterFetchedAt };
  } catch (err) {
    return {
      ok: false,
      error: err instanceof Error ? err.message : String(err),
    };
  }
}

export interface ApplyState {
  ok: boolean;
  appliedCount?: number;
  skippedCount?: number;
  error?: string;
}

// Payload per checked row, encoded into a hidden input on the form.
interface PayloadV1 {
  v: 1;
  input_price: number | null;
  cached_input_price: number | null;
  output_price: number | null;
  cache_write_price: number | null;
}

function parsePayload(raw: FormDataEntryValue | null): PayloadV1 | null {
  if (typeof raw !== 'string' || !raw) return null;
  try {
    const o = JSON.parse(raw) as Record<string, unknown>;
    if (o.v !== 1) return null;
    const num = (k: keyof PayloadV1): number | null => {
      const v = o[k];
      if (v === null || v === undefined) return null;
      const n = typeof v === 'number' ? v : Number(v);
      return Number.isFinite(n) && n >= 0 ? n : null;
    };
    return {
      v: 1,
      input_price: num('input_price'),
      cached_input_price: num('cached_input_price'),
      output_price: num('output_price'),
      cache_write_price: num('cache_write_price'),
    };
  } catch {
    return null;
  }
}

export async function applyUpstreamPrices(
  _prev: ApplyState,
  formData: FormData,
): Promise<ApplyState> {
  const admin = await requireAdmin();
  const supa = supabaseAdmin();

  const ids = formData
    .getAll('apply')
    .filter((v): v is string => typeof v === 'string' && v.length > 0);
  if (ids.length === 0) {
    return { ok: false, error: '没有勾选任何行' };
  }

  // Pull current values up front so admin_audit captures before/after
  // for each updated alias.
  const { data: beforeRows, error: beforeErr } = await supa
    .from('llm_model_aliases')
    .select(
      'id, input_price, cached_input_price, output_price, cache_write_price',
    )
    .in('id', ids);
  if (beforeErr) return { ok: false, error: beforeErr.message };
  const beforeById = new Map(
    (beforeRows ?? []).map((r) => [r.id, r] as const),
  );

  let applied = 0;
  let skipped = 0;
  const h = await headers();
  const ip = h.get('x-forwarded-for') ?? null;
  const ua = h.get('user-agent') ?? null;

  for (const id of ids) {
    const payload = parsePayload(formData.get(`payload:${id}`));
    const before = beforeById.get(id);
    if (!payload || !before) {
      skipped += 1;
      continue;
    }
    // input_price + output_price are NOT NULL in schema — if upstream
    // didn't expose them, keep the existing value rather than writing
    // null and tripping the constraint.
    const newRow = {
      input_price: payload.input_price ?? (before.input_price as number),
      output_price: payload.output_price ?? (before.output_price as number),
      // Optional columns: null is a valid stored value.
      cached_input_price: payload.cached_input_price,
      cache_write_price: payload.cache_write_price,
      updated_at: new Date().toISOString(),
    };
    const { error: updErr } = await supa
      .from('llm_model_aliases')
      .update(newRow)
      .eq('id', id);
    if (updErr) {
      skipped += 1;
      continue;
    }
    await supa.from('admin_audit').insert({
      actor_id: admin.id,
      action: 'alias.update_from_upstream',
      target_kind: 'llm_model_alias',
      target_id: id,
      before: before as never,
      after: newRow as never,
      ip,
      user_agent: ua,
    });
    applied += 1;
  }

  revalidatePath('/aliases');
  revalidatePath('/aliases/upstream');
  return { ok: true, appliedCount: applied, skippedCount: skipped };
}
