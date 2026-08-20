#!/usr/bin/env bun
// List recent user↔bot conversations with enough context to pick one
// for `envelope-replay.ts`. Service-role read against the configured
// Supabase (apps/edge/.dev.vars) — sees all conversations, regardless
// of RLS.
//
// 用法:
//   bun run apps/edge/scripts/envelope-list-convs.ts [--limit 20] [--user <id>] [--bot <id>]
//
// Output (TSV-ish): id  updated_at  bot_name  user_id  msg_count  last_msg_preview

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createClient } from '@supabase/supabase-js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const EDGE_ROOT = path.resolve(__dirname, '..');

const argv = process.argv.slice(2);
function flag(name: string): string | undefined {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
}
const limit = Math.max(1, Math.min(100, Number(flag('--limit') ?? 20)));
const userFilter = flag('--user');
const botFilter = flag('--bot');

// Merge ~/.config/pendingbot/.dev.vars (user-global) then apps/edge/.dev.vars
// (project, wins on conflict). Either may be missing.
function parseDotenv(text: string, into: Record<string, string>): void {
  for (const line of text.split('\n')) {
    const t = line.trim();
    if (!t || t.startsWith('#')) continue;
    const m = line.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/);
    if (m) {
      let v = m[2];
      if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
      // Skip empty so half-filled project-local .dev.vars doesn't clobber
      // a non-empty value from the global stash.
      if (v) into[m[1]] = v;
    }
  }
}
function loadDevVars(): Record<string, string> {
  const env: Record<string, string> = {};
  const home = process.env.HOME ?? '';
  for (const file of [
    home ? path.join(home, '.config/pendingbot/.dev.vars') : '',
    path.join(EDGE_ROOT, '.dev.vars'),
  ].filter(Boolean)) {
    try {
      parseDotenv(fs.readFileSync(file, 'utf8'), env);
    } catch {
      // optional
    }
  }
  return env;
}
const env = loadDevVars();
const supa = createClient(env.SUPABASE_URL!, env.SUPABASE_SECRET_KEY!, {
  auth: { autoRefreshToken: false, persistSession: false },
  db: { schema: 'pendingbot' },
});

const isTTY = process.stdout.isTTY;
const dim = (s: string) => (isTTY ? `\x1b[2m${s}\x1b[0m` : s);
const cyan = (s: string) => (isTTY ? `\x1b[36m${s}\x1b[0m` : s);
const bold = (s: string) => (isTTY ? `\x1b[1m${s}\x1b[0m` : s);

async function main(): Promise<void> {
  let q = supa
    .from('conversations')
    .select('id, bot_id, user_id, updated_at, title')
    .not('bot_id', 'is', null)
    .not('user_id', 'is', null)
    .order('updated_at', { ascending: false })
    .limit(limit);
  if (userFilter) q = q.eq('user_id', userFilter);
  if (botFilter) q = q.eq('bot_id', botFilter);

  const { data: convs, error } = await q;
  if (error) throw new Error(`conversations: ${error.message}`);
  if (!convs?.length) {
    console.log('(no conversations)');
    return;
  }

  // Batch the bot lookup so we get display_names in one round-trip.
  const botIds = [...new Set(convs.map((c) => c.bot_id as string))];
  const { data: bots } = await supa
    .from('bots')
    .select('id, display_name')
    .in('id', botIds);
  const botName = new Map((bots ?? []).map((b) => [b.id as string, (b.display_name as string) ?? '']));

  // Per-conv: latest non-log message (preview) + count. Two queries each
  // — fine for a dev tool with a small limit.
  console.log(
    bold(['id', 'updated_at', 'bot', 'user', 'msgs', 'last_message'].join('  ')),
  );
  for (const c of convs) {
    const [latest, count] = await Promise.all([
      supa
        .from('messages')
        .select('role, content, created_at')
        .eq('conversation_id', c.id as string)
        .neq('role', 'log')
        .order('created_at', { ascending: false })
        .limit(1)
        .maybeSingle(),
      supa
        .from('messages')
        .select('id', { count: 'exact', head: true })
        .eq('conversation_id', c.id as string)
        .neq('role', 'log'),
    ]);
    const preview = latest.data?.content
      ? (latest.data.content as string).replace(/\s+/g, ' ').slice(0, 60)
      : '(empty)';
    const role = latest.data?.role ?? '';
    const msgs = count.count ?? 0;
    console.log(
      [
        cyan(c.id as string),
        dim((c.updated_at as string).slice(0, 19).replace('T', ' ')),
        botName.get(c.bot_id as string) || dim('(unnamed)'),
        dim((c.user_id as string).slice(0, 8)),
        String(msgs).padStart(3, ' '),
        dim(`[${role}]`) + ' ' + preview,
      ].join('  '),
    );
  }
}

main().catch((err) => {
  console.error('list-convs failed:', err);
  process.exit(1);
});
