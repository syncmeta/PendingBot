// Live model catalog — a thin cached read of OpenRouter's public model
// list. There is no DB-backed catalog anymore; model metadata (vision
// capability, context window) is pulled from upstream and cached on the
// worker isolate for a few minutes. A failed fetch keeps any prior cache
// and retries on the next call.

const CATALOG_TTL_MS = 5 * 60_000;

interface CatalogEntry {
  visionCapable: boolean;
  contextWindow: number | null;
}

let cache: { at: number; byId: Map<string, CatalogEntry> } | null = null;

async function getCatalog(): Promise<Map<string, CatalogEntry> | null> {
  const now = Date.now();
  if (cache && now - cache.at < CATALOG_TTL_MS) return cache.byId;
  try {
    const res = await fetch('https://openrouter.ai/api/v1/models');
    if (!res.ok) {
      console.warn('[catalog] openrouter catalog', res.status);
      return cache?.byId ?? null;
    }
    const json = (await res.json()) as {
      data?: Array<{
        id?: string;
        context_length?: number;
        architecture?: { input_modalities?: string[] };
      }>;
    };
    const byId = new Map<string, CatalogEntry>();
    for (const m of json.data ?? []) {
      if (typeof m.id !== 'string') continue;
      byId.set(m.id, {
        visionCapable: (m.architecture?.input_modalities ?? []).includes('image'),
        contextWindow:
          typeof m.context_length === 'number' ? m.context_length : null,
      });
    }
    cache = { at: now, byId };
    return byId;
  } catch (err) {
    console.warn('[catalog] openrouter catalog fetch failed', err);
    return cache?.byId ?? null;
  }
}

/// True iff OpenRouter lists this model id as accepting image input.
/// Unknown slugs return false — conservatively assume no vision so the
/// caller routes through the 'vision' model-role default.
export async function modelSupportsVision(slug: string): Promise<boolean> {
  if (!slug) return false;
  const byId = await getCatalog();
  return byId?.get(slug)?.visionCapable ?? false;
}

/// OpenRouter's advertised context window for a model id, or null when
/// the model / catalog is unknown — the caller substitutes its own
/// fallback.
export async function modelContextWindow(slug: string): Promise<number | null> {
  if (!slug) return null;
  const byId = await getCatalog();
  return byId?.get(slug)?.contextWindow ?? null;
}
