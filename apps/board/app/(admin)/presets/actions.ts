'use server';

import { headers } from 'next/headers';
import { revalidatePath } from 'next/cache';
import { requireAdmin } from '@/lib/auth';
import { supabaseAdmin } from '@/lib/supabase/admin';
import type { Json } from '@pendingbot/edge/db/schema';
import type { SavePresetState } from './_shared';

function text(formData: FormData, key: string) {
  return String(formData.get(key) ?? '').trim();
}

function parseJsonArray(raw: string, label: string): Json {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error(`${label} 必须是合法 JSON`);
  }
  if (!Array.isArray(parsed)) throw new Error(`${label} 必须是数组`);
  return parsed as Json;
}

async function audit(
  actorId: string,
  action: string,
  targetKind: string,
  targetId: string,
  before: unknown,
  after: unknown,
) {
  const supa = supabaseAdmin();
  const h = await headers();
  await supa.from('admin_audit').insert({
    actor_id: actorId,
    action,
    target_kind: targetKind,
    target_id: targetId,
    before: before as never,
    after: after as never,
    ip: h.get('x-forwarded-for') ?? null,
    user_agent: h.get('user-agent') ?? null,
  });
}

export async function savePresetConversation(
  _prev: SavePresetState,
  formData: FormData,
): Promise<SavePresetState> {
  const admin = await requireAdmin();
  const slug = text(formData, 'slug');
  const bot_slug = text(formData, 'bot_slug');
  const title = text(formData, 'title');
  const base_ts = text(formData, 'base_ts') || '1970-01-01T00:00:00.000Z';
  const sort_order = Number(text(formData, 'sort_order') || '100');
  const enabled = formData.get('enabled') === 'on';
  const rawMessages = String(formData.get('messages') ?? '[]');

  try {
    if (!slug) return { error: 'slug 不能为空' };
    if (!bot_slug) return { error: 'bot slug 不能为空' };
    if (!title) return { error: '标题不能为空' };
    if (!Number.isFinite(sort_order)) return { error: '排序必须是数字' };
    const messages = parseJsonArray(rawMessages, '消息');

    const supa = supabaseAdmin();
    const { data: before } = await supa
      .from('preset_conversation_templates')
      .select('*')
      .eq('slug', slug)
      .maybeSingle();

    const next = {
      slug,
      bot_slug,
      title,
      base_ts,
      sort_order,
      enabled,
      messages,
      updated_at: new Date().toISOString(),
      updated_by: admin.id,
    };
    const { error } = await supa
      .from('preset_conversation_templates')
      .upsert(next, { onConflict: 'slug' });
    if (error) return { error: error.message, slug };

    await audit(
      admin.id,
      'preset_conversation_templates.upsert',
      'preset_conversation_templates',
      slug,
      before,
      next,
    );
    revalidatePath('/presets');
    return { ok: true, slug };
  } catch (err) {
    return { error: err instanceof Error ? err.message : String(err), slug };
  }
}

export async function savePresetGroup(
  _prev: SavePresetState,
  formData: FormData,
): Promise<SavePresetState> {
  const admin = await requireAdmin();
  const slug = text(formData, 'slug');
  const title = text(formData, 'title');
  const bot_slugs = text(formData, 'bot_slugs')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
  const join_policy = text(formData, 'join_policy') as 'scan_open' | 'approval' | 'closed';
  const sort_order = Number(text(formData, 'sort_order') || '100');
  const enabled = formData.get('enabled') === 'on';
  const rawMessages = String(formData.get('messages') ?? '[]');

  try {
    if (!slug) return { error: 'slug 不能为空' };
    if (!title) return { error: '标题不能为空' };
    if (bot_slugs.length === 0) return { error: '至少需要一个 bot slug' };
    if (!['scan_open', 'approval', 'closed'].includes(join_policy)) {
      return { error: '加群方式无效', slug };
    }
    if (!Number.isFinite(sort_order)) return { error: '排序必须是数字', slug };
    const messages = parseJsonArray(rawMessages, '消息');

    const supa = supabaseAdmin();
    const { data: before } = await supa
      .from('preset_group_templates')
      .select('*')
      .eq('slug', slug)
      .maybeSingle();

    const next = {
      slug,
      title,
      bot_slugs,
      join_policy,
      sort_order,
      enabled,
      messages,
      updated_at: new Date().toISOString(),
      updated_by: admin.id,
    };
    const { error } = await supa
      .from('preset_group_templates')
      .upsert(next, { onConflict: 'slug' });
    if (error) return { error: error.message, slug };

    await audit(
      admin.id,
      'preset_group_templates.upsert',
      'preset_group_templates',
      slug,
      before,
      next,
    );
    revalidatePath('/presets');
    return { ok: true, slug };
  } catch (err) {
    return { error: err instanceof Error ? err.message : String(err), slug };
  }
}
