import { Hono } from 'hono';
import { requireSession } from '@pendingbot/identity';
import type { Env } from '../types';
import { serviceClient } from '../lib/supabase';
import { resolveModelPreset, makeCatalogProvider, MODEL_PRESETS_LIST_CACHE_KEY, type PresetDef } from '../lib/model-presets';

export const modelPresetsRoutes = new Hono<{ Bindings: Env }>();

// Auth like /v1/models — preset resolution can trigger up-to-40 per-model
// OpenRouter endpoint fetches on a cold cache, so don't expose it anonymously.
modelPresetsRoutes.use('*', requireSession());

const LIST_CACHE_KEY = MODEL_PRESETS_LIST_CACHE_KEY;
const LIST_TTL_SEC = 60 * 60;

modelPresetsRoutes.get('/', async (c) => {
  const cached = await c.env.MEMORY.get(LIST_CACHE_KEY, 'json').catch(() => null);
  if (cached) return c.json(cached);

  const db = serviceClient(c.env).schema('pendingbot');
  const { data, error } = await db
    .from('model_presets')
    .select('slug, title, description, resolver_kind, params, default_selected')
    .eq('enabled', true)
    .order('sort_order', { ascending: true });
  if (error) throw error;

  const defs = (data ?? []) as unknown as PresetDef[];
  // 一份目录喂所有预设（避免每个预设各自 build catalog 的 N× 冷启动开销）。
  const provider = makeCatalogProvider(c.env);
  const resolved = await Promise.all(defs.map((d) => resolveModelPreset(c.env, d, provider)));
  await c.env.MEMORY.put(LIST_CACHE_KEY, JSON.stringify(resolved), {
    expirationTtl: LIST_TTL_SEC,
  }).catch(() => {});
  return c.json(resolved);
});
