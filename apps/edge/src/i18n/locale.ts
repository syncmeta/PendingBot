// Per-request locale resolution.
//
// Priority:
//   1. pendingbot.users.locale (when userId is known) — KV-cached
//   2. Accept-Language header — first weighted tag we support
//   3. DEFAULT_LOCALE ('zh')
//
// Unknown values normalize back to DEFAULT_LOCALE rather than throwing, so
// handlers can always treat the result as a valid Locale.
//
// KV cache `locale:${userId}` (1h TTL) skips a Supabase RTT on the hot
// path. Locale changes via iOS settings; staleness is bounded by TTL.

import type { Env } from '../types';
import type { SupabaseClient } from '../lib/supabase';
import { DEFAULT_LOCALE, isLocale, normalizeLocale, type Locale } from './types';

const LOCALE_PREFIX = 'locale:';
const LOCALE_TTL_SEC = 3600;

export async function resolveLocale(
  req: Request | { headers: Headers } | null,
  supa: SupabaseClient | null,
  userId: string | null,
  env: Env | null = null,
): Promise<Locale> {
  if (userId && env) {
    const cached = await env.MEMORY.get(LOCALE_PREFIX + userId, 'text');
    if (cached) return normalizeLocale(cached);
  }
  if (userId && supa) {
    const { data } = await supa
      .from('user_settings')
      .select('locale')
      .eq('user_id', userId)
      .maybeSingle();
    if (data?.locale) {
      const loc = normalizeLocale(data.locale);
      if (env) {
        await env.MEMORY.put(LOCALE_PREFIX + userId, loc, {
          expirationTtl: LOCALE_TTL_SEC,
        }).catch(() => undefined);
      }
      return loc;
    }
  }

  const accept = req?.headers.get('Accept-Language');
  if (accept) {
    // Walk q-value-ordered tags; first base we recognize wins.
    const tags = accept
      .split(',')
      .map((part) => {
        const [tag, q] = part.split(';').map((s) => s.trim());
        const weight = q?.startsWith('q=') ? Number(q.slice(2)) : 1;
        return { tag: tag.toLowerCase(), weight: Number.isFinite(weight) ? weight : 0 };
      })
      .filter((t) => t.tag)
      .sort((a, b) => b.weight - a.weight);
    for (const { tag } of tags) {
      const base = tag.split(/[-_]/)[0];
      if (isLocale(base)) return base;
    }
  }

  return DEFAULT_LOCALE;
}
