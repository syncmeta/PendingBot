import { Hono } from 'hono';
import { requireSession } from '@pendingbot/identity';
import type { AppBindings } from '../types';

// GET /v1/openrouter/models — proxy OpenRouter's catalog, reshaped for the
// iOS model picker. We strip pricing/metadata the client doesn't render and
// keep slug/display_name/provider/context_length only. Provider strategy
// (WorldRouter primary, OpenRouter fallback) doesn't change the catalog —
// model IDs are OpenRouter-style on both sides.

export const openrouterRoutes = new Hono<AppBindings>();
openrouterRoutes.use('*', requireSession());

interface OpenRouterCatalogModel {
  id: string;
  name?: string;
  context_length?: number;
  /// OpenRouter exposes per-model `architecture.input_modalities` like
  /// ["text","image","video"]. We surface a derived boolean so the iOS
  /// vision-model picker can filter without having to know the schema.
  architecture?: {
    input_modalities?: string[];
  };
}

interface OpenRouterModelOut {
  slug: string;
  display_name: string;
  provider: string;
  context_length: number | null;
  /// True when the model accepts image input. The vision-model picker
  /// in ConversationSettingsView filters on this.
  supports_vision: boolean;
}

openrouterRoutes.get('/models', async (c) => {
  const res = await fetch('https://openrouter.ai/api/v1/models', {
    headers: { Authorization: `Bearer ${c.env.OPENROUTER_API_KEY}` },
  });
  if (!res.ok) {
    const body = (await res.text()).slice(0, 300);
    console.warn('[openrouter/models] upstream', res.status, body);
    return c.json({ error: 'upstream_failed', status: res.status }, 502);
  }
  const json = (await res.json()) as { data?: OpenRouterCatalogModel[] };
  const out: OpenRouterModelOut[] = (json.data ?? []).map((m) => {
    const slash = m.id.indexOf('/');
    const provider = slash > 0 ? m.id.slice(0, slash) : 'unknown';
    const tail = slash > 0 ? m.id.slice(slash + 1) : m.id;
    // OpenRouter's "name" is "Vendor: Model" — strip the vendor prefix so
    // the picker's section header isn't redundant with the row title.
    const displayName = stripVendorPrefix(m.name) ?? prettifyTail(tail);
    const inputModalities = m.architecture?.input_modalities ?? [];
    return {
      slug: m.id,
      display_name: displayName,
      provider,
      context_length: typeof m.context_length === 'number' ? m.context_length : null,
      supports_vision: inputModalities.includes('image'),
    };
  });
  return c.json(out);
});

function stripVendorPrefix(name?: string): string | null {
  if (!name) return null;
  const idx = name.indexOf(': ');
  return idx >= 0 ? name.slice(idx + 2) : name;
}

function prettifyTail(tail: string): string {
  return tail.replace(/[-_]/g, ' ');
}
