import { Hono } from 'hono';
import type { Env } from '../types';
import { serviceClient } from '../lib/supabase';
import { resolveModelPreset, type PresetDef } from '../lib/model-presets';

export const modelPresetsRoutes = new Hono<{ Bindings: Env }>();

const LIST_CACHE_KEY = 'model_presets:list:v1';
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
  const resolved = await Promise.all(defs.map((d) => resolveModelPreset(c.env, d)));
  await c.env.MEMORY.put(LIST_CACHE_KEY, JSON.stringify(resolved), {
    expirationTtl: LIST_TTL_SEC,
  }).catch(() => {});
  return c.json(resolved);
});
