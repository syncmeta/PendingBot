import type { Env } from '../types';
import { serviceClient } from '../lib/supabase';
import {
  resolveModelPreset,
  makeCatalogProvider,
  bustModelPresetCaches,
  MODEL_PRESETS_LIST_CACHE_KEY,
  type PresetDef,
} from '../lib/model-presets';

// 模型预设缓存预热（每 30min 由 cron 触发）。
//
// 没有预热时，每个缓存周期的第一个用户（打开建机器人页 → GET /v1/model-presets）
// 要扛满冷计算：build catalog（OpenRouter 全目录 + LMArena 14 个 subset 分页）+
// fastest 预设逐模型探测吞吐。表现为"列表时快时极慢"。
//
// 预热把这套冷成本搬到后台：清旧缓存 → 用一份共享目录（makeCatalogProvider，
// 冷启动只 build 一次而非 N 次）重算所有 enabled 预设 → 回填 per-preset + list KV。
// 用户路径于是永远命中缓存。
//
// list TTL 给 2h（> 30min 预热间隔），cron 偶尔漏跑也不会立刻空窗。
const LIST_TTL_SEC = 2 * 60 * 60;

export async function warmModelPresets(env: Env): Promise<void> {
  const db = serviceClient(env).schema('pendingbot');
  const { data, error } = await db
    .from('model_presets')
    .select('slug, title, description, resolver_kind, params, default_selected')
    .eq('enabled', true)
    .order('sort_order', { ascending: true });
  if (error) throw new Error(error.message);
  const defs = (data ?? []) as unknown as PresetDef[];
  if (defs.length === 0) return;

  // 先清缓存：resolveModelPreset 命中旧 cache 会直接返回，不会刷新，所以预热必须
  // 先 bust 才能拿到新目录算出的结果。bust 到回填之间的窗口若有用户请求，最多触发
  // 一次 lazy 重算，无害。
  await bustModelPresetCaches(env);
  for (const d of defs) await bustModelPresetCaches(env, d.slug);

  // 共享 provider：所有预设复用同一份目录，整个预热只 build catalog 一次。
  const provider = makeCatalogProvider(env);
  const resolved = await Promise.all(defs.map((d) => resolveModelPreset(env, d, provider)));
  await env.MEMORY.put(MODEL_PRESETS_LIST_CACHE_KEY, JSON.stringify(resolved), {
    expirationTtl: LIST_TTL_SEC,
  });
}
