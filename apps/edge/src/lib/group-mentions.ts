import type { SupabaseClient } from './supabase';

// Parse @-mentions out of a group message and resolve them to bot ids.
// Only bot mentions matter for routing — human @-mentions are pure
// rendering and don't trigger anything server-side. Match strategy:
//
//   /@(\S{1,32})/g — @ followed by up to 32 non-whitespace chars.
//
// We then look those up against (conversation_participants.nickname)
// and (bots.display_name) for bots in this group, in that priority
// order. Case-insensitive. Quotes/punctuation around the mention are
// stripped so "@SciBot," matches "SciBot".

const MENTION_RE = /@([\p{L}\p{N}_\-]{1,32})/gu;

export async function resolveGroupMentions(
  supa: SupabaseClient,
  conversationId: string,
  text: string,
): Promise<string[]> {
  const tokens = extractMentionTokens(text);
  if (tokens.length === 0) return [];

  const { data: parts } = await supa
    .from('conversation_participants')
    .select('participant_id, nickname')
    .eq('conversation_id', conversationId)
    .eq('participant_type', 'bot');
  if (!parts || parts.length === 0) return [];

  const botIds = parts.map((p) => p.participant_id as string);
  const { data: bots } = await supa
    .from('bots')
    .select('id, display_name')
    .in('id', botIds);

  // Build a lowercase-keyed lookup: nickname → bot id, then display_
  // name → bot id (only filled if no nickname row claims that key).
  const lookup = new Map<string, string>();
  for (const p of parts) {
    const nick = p.nickname as string | null;
    if (nick && nick.length > 0) {
      lookup.set(nick.toLowerCase(), p.participant_id as string);
    }
  }
  for (const b of bots ?? []) {
    const name = (b.display_name as string).toLowerCase();
    if (!lookup.has(name)) {
      lookup.set(name, b.id as string);
    }
  }

  const matched: string[] = [];
  const seen = new Set<string>();
  for (const t of tokens) {
    const id = lookup.get(t.toLowerCase());
    if (id && !seen.has(id)) {
      matched.push(id);
      seen.add(id);
    }
  }
  return matched;
}

function extractMentionTokens(text: string): string[] {
  const out: string[] = [];
  for (const match of text.matchAll(MENTION_RE)) {
    out.push(match[1]);
  }
  return out;
}
