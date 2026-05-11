// Per-request locale resolution.
//
// Priority:
//   1. pendingbot.users.locale (when userId is known)
//   2. Accept-Language header — first weighted tag we support
//   3. DEFAULT_LOCALE ('zh')
//
// Unknown values normalize back to DEFAULT_LOCALE rather than throwing, so
// handlers can always treat the result as a valid Locale.

import type { SupabaseClient } from '../lib/supabase';
import { DEFAULT_LOCALE, isLocale, normalizeLocale, type Locale } from './types';

export async function resolveLocale(
  req: Request | { headers: Headers } | null,
  supa: SupabaseClient | null,
  userId: string | null,
): Promise<Locale> {
  if (userId && supa) {
    const { data } = await supa
      .from('user_settings')
      .select('locale')
      .eq('user_id', userId)
      .maybeSingle();
    if (data?.locale) {
      return normalizeLocale(data.locale);
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
