// One-shot migration: push the bundled prompts/<locale>/<name>.md files into
// Langfuse Prompt Management as text prompts under the `production` label.
//
// This is the seeding step that makes Langfuse the single source of truth for
// prompts. After it runs (and KV/webhook wiring lands), the .md files are
// deleted — Langfuse owns the prompts from then on.
//
// Run from apps/edge with the Langfuse keys exported (they live in .dev.vars):
//   export LANGFUSE_PUBLIC_KEY=... LANGFUSE_SECRET_KEY=... LANGFUSE_BASE_URL=...
//   bun run scripts/seed-langfuse-prompts.ts
//
// Idempotent: for each `<name>/<locale>`, if the current `production` version
// already has identical body, it's skipped; otherwise a new version is created
// and labelled production. Safe to re-run.
//
// Naming matches prompt-loader: `<name>/<locale>` (e.g. `system/zh`).

import { readdir, readFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Langfuse } from 'langfuse';
import { PROMPT_NAMES } from '../src/llm/prompt-names';

const LABEL = 'production';
const PROMPTS_DIR = join(dirname(fileURLToPath(import.meta.url)), '..', 'prompts');
const NAMESET = new Set<string>(PROMPT_NAMES);

const publicKey = process.env.LANGFUSE_PUBLIC_KEY;
const secretKey = process.env.LANGFUSE_SECRET_KEY;
const baseUrl = process.env.LANGFUSE_BASE_URL;

if (!publicKey || !secretKey) {
  console.error('Missing LANGFUSE_PUBLIC_KEY / LANGFUSE_SECRET_KEY in env. Export them from .dev.vars first.');
  process.exit(1);
}

const lf = new Langfuse({ publicKey, secretKey, baseUrl });

async function currentProductionBody(lfName: string): Promise<string | null> {
  try {
    const cur = await lf.getPrompt(lfName, undefined, { label: LABEL, type: 'text', cacheTtlSeconds: 0 });
    return typeof cur.prompt === 'string' ? cur.prompt : null;
  } catch {
    return null; // not created yet
  }
}

let created = 0;
let skipped = 0;
let failed = 0;

const localeDirs = (await readdir(PROMPTS_DIR, { withFileTypes: true }))
  .filter((d) => d.isDirectory())
  .map((d) => d.name);

for (const locale of localeDirs) {
  const dir = join(PROMPTS_DIR, locale);
  const files = (await readdir(dir)).filter((f) => f.endsWith('.md'));
  for (const file of files) {
    const name = file.replace(/\.md$/, '');
    if (!NAMESET.has(name)) {
      console.log(`skip (not a PROMPT_NAME): ${locale}/${file}`);
      continue;
    }
    const lfName = `${name}/${locale}`;
    const body = await readFile(join(dir, file), 'utf8');
    try {
      const existing = await currentProductionBody(lfName);
      if (existing === body) {
        skipped++;
        console.log(`skip (unchanged): ${lfName}`);
        continue;
      }
      await lf.createPrompt({ type: 'text', name: lfName, prompt: body, labels: [LABEL] });
      created++;
      console.log(`${existing === null ? 'created' : 'new version'}: ${lfName}`);
    } catch (e) {
      failed++;
      console.error(`FAILED: ${lfName}`, e);
    }
  }
}

await lf.flushAsync();
console.log(`\ndone: created=${created} skipped=${skipped} failed=${failed}`);
if (failed > 0) process.exit(1);
