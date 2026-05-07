#!/usr/bin/env node
// Seed every bundled skill under prompts/skills/<vendor>/*.md as a
// system-public skills row. Idempotent: looks up each skill by
// frontmatter.name and skips if it exists; otherwise INSERTs with
// owner_id=null, visibility='public'.
//
// Vendors currently shipped:
//   anthropic/   — Apache-2.0 vendored copies (see anthropic/NOTICE.md)
//   pendingbot/  — first-party skills (e.g. code-runner gating execute_code)
//
// Run after each new migration that touches skills, or whenever bundled
// skill content changes. Reads .dev.vars for service-role credentials so
// secrets don't pass through argv.

import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const SKILLS_DIR = path.join(ROOT, 'prompts/skills');

// Skip NOTICE / LICENSE / README at any depth.
const SKIP_BASENAMES = new Set(['NOTICE.md', 'LICENSE.md', 'README.md']);

function parseFrontmatter(raw) {
  if (!raw.startsWith('---')) return { frontmatter: {}, body: raw };
  const end = raw.indexOf('\n---', 3);
  if (end === -1) return { frontmatter: {}, body: raw };
  const head = raw.slice(3, end).trim();
  const body = raw.slice(end + 4).replace(/^\s*\n/, '');
  const frontmatter = {};
  for (const line of head.split('\n')) {
    const m = line.match(/^([a-zA-Z_][a-zA-Z0-9_-]*):\s*(.+)$/);
    if (!m) continue;
    let val = m[2].trim();
    // Inline JSON arrays/objects — e.g. allowed_tools: ["execute_code"] —
    // round-trip through JSON.parse so they land in jsonb as real arrays
    // instead of strings (the 0026 frontmatter CHECK requires array typeof
    // for allowed_tools).
    if ((val.startsWith('[') && val.endsWith(']')) ||
        (val.startsWith('{') && val.endsWith('}'))) {
      try { val = JSON.parse(val); } catch { /* keep as string on parse fail */ }
    }
    frontmatter[m[1]] = val;
  }
  return { frontmatter, body };
}

async function* walkSkills(dir) {
  for (const entry of await fs.readdir(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      yield* walkSkills(full);
    } else if (
      entry.isFile() &&
      entry.name.endsWith('.md') &&
      !SKIP_BASENAMES.has(entry.name)
    ) {
      yield full;
    }
  }
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

let inserted = 0;
let skipped = 0;
for await (const file of walkSkills(SKILLS_DIR)) {
  const raw = await fs.readFile(file, 'utf8');
  const { frontmatter, body } = parseFrontmatter(raw);
  if (!frontmatter.name) {
    console.warn(`skip ${path.relative(SKILLS_DIR, file)} — no name in frontmatter`);
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
