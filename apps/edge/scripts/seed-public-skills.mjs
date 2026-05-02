#!/usr/bin/env node
// Seed the bundled Anthropic Claude Skills as system-public skills rows.
// Idempotent: looks up each skill by frontmatter.name and skips if it
// exists; otherwise INSERTs with owner_id=null, visibility='public'.
//
// Run once after migration 0004 lands. Reads .dev.vars for service-role
// credentials so secrets don't pass through argv.

import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const SKILLS_DIR = path.join(ROOT, 'prompts/skills/anthropic');

function parseFrontmatter(raw) {
  if (!raw.startsWith('---')) return { frontmatter: {}, body: raw };
  const end = raw.indexOf('\n---', 3);
  if (end === -1) return { frontmatter: {}, body: raw };
  const head = raw.slice(3, end).trim();
  const body = raw.slice(end + 4).replace(/^\s*\n/, '');
  const frontmatter = {};
  for (const line of head.split('\n')) {
    const m = line.match(/^([a-zA-Z_][a-zA-Z0-9_-]*):\s*(.+)$/);
    if (m) frontmatter[m[1]] = m[2].trim();
  }
  return { frontmatter, body };
}

async function loadDevVars() {
  const text = await fs.readFile(path.join(ROOT, '.dev.vars'), 'utf8');
  const env = {};
  for (const line of text.split('\n')) {
    const m = line.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/);
    if (m) env[m[1]] = m[2];
  }
  return env;
}

const env = await loadDevVars();
const SUPABASE_URL = env.SUPABASE_URL;
const SR = env.SUPABASE_SERVICE_ROLE_KEY;
if (!SUPABASE_URL || !SR) {
  console.error('missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY in .dev.vars');
  process.exit(1);
}

const headers = {
  apikey: SR,
  Authorization: `Bearer ${SR}`,
  'Content-Type': 'application/json',
  'Content-Profile': 'pendingbot',
  'Accept-Profile': 'pendingbot',
  Prefer: 'return=representation',
};

const files = (await fs.readdir(SKILLS_DIR))
  .filter((f) => f.endsWith('.md') && f !== 'NOTICE.md');

let inserted = 0;
let skipped = 0;
for (const file of files) {
  const raw = await fs.readFile(path.join(SKILLS_DIR, file), 'utf8');
  const { frontmatter, body } = parseFrontmatter(raw);
  if (!frontmatter.name) {
    console.warn(`skip ${file} — no name in frontmatter`);
    continue;
  }

  // Existence check: any system-public row with the same name?
  const lookup = await fetch(
    `${SUPABASE_URL}/rest/v1/skills?select=id&owner_id=is.null&bot_id=is.null&frontmatter->>name=eq.${encodeURIComponent(frontmatter.name)}`,
    { headers },
  );
  const found = await lookup.json();
  if (Array.isArray(found) && found.length > 0) {
    skipped++;
    continue;
  }

  const res = await fetch(`${SUPABASE_URL}/rest/v1/skills`, {
    method: 'POST',
    headers,
    body: JSON.stringify({
      owner_id: null,
      bot_id: null,
      user_id: null,
      visibility: 'public',
      frontmatter,
      body_md: body,
    }),
  });
  if (!res.ok) {
    console.error(`insert ${frontmatter.name} failed: ${res.status} ${(await res.text()).slice(0, 200)}`);
    continue;
  }
  inserted++;
}

console.log(`done. inserted=${inserted} skipped=${skipped}`);
