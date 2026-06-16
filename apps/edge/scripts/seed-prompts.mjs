#!/usr/bin/env node
// Seed the prompts that were migrated out of inline `const` strings into
// Langfuse Prompt Management (audit R4 / no_hardcoded_prompts / #247).
//
// Langfuse is the SINGLE SOURCE OF TRUTH for prompt bodies — the edge worker
// reads them via prompt-loader.ts (KV cache + pull-on-miss from Langfuse,
// production label). This script pushes the initial bodies so a fresh
// Langfuse project has the `production`-labelled versions the loader expects.
//
// Idempotent-ish: Langfuse's POST /api/public/v2/prompts creates a NEW VERSION
// each call and moves the `production` label to it. Re-running just bumps the
// version with identical content (harmless) — it does NOT dedupe. Run once per
// fresh Langfuse project; after that, edit in the Langfuse console instead.
//
// Naming: each prompt is stored as `<name>/<locale>` (the loader's
// langfuseName() shape). These four are zh-only (DEFAULT_LOCALE), so the
// Langfuse name is `<name>/zh`.
//
// Reads LANGFUSE_PUBLIC_KEY / LANGFUSE_SECRET_KEY / LANGFUSE_BASE_URL from
// apps/edge/.dev.vars so secrets don't pass through argv. Does NOT touch the
// worker's runtime secrets.

import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');

const LOCALE = 'zh'; // DEFAULT_LOCALE — all four prompts are zh-only.
const PRODUCTION_LABEL = 'production';

// ── prompt bodies ─────────────────────────────────────────────────────────
// These MUST stay byte-identical to the strings that were inlined before the
// migration. Keep this block as the canonical source for re-seeding.

const LOOKBACK_INSTRUCTION = `以上是你和对方刚刚的聊天记录。

现在系统让你回头看看：你或对方有没有传达过未经查证的信息？

注意：
- 你和对方都不一定是对的。不仅要查证自己说的话，也要看看对方说的是否正确。你们都有可能凭借不实印象信口开河。
- 这是系统自动让你做的回顾，对方不会看到你这次的输出原文。
- 你的输出只会被注入到「下一次回复对方时的你自己」的上下文里，让那时候的你知道这次查证的成果。
- 如果有可以查证的工具/能力，可以使用。
- 如果查证后发现没什么需要说明、更正的，或是没有查证必要的，直接输出 [SILENT] 一个 token 即可。
- 否则，写一段短笔记（控制在 200 字以内）—— 给"下次的你"看，提醒「上一轮里这点其实不太对/需要补正」。

直接开始你的笔记或者 [SILENT]，不要任何前言。`;

const IMAGE_SUMMARY =
  '请观察这张图片，输出严格的 JSON（不要 markdown 代码块），格式：' +
  '{"summary":"一两句中文描述，包含画面主体和氛围","tags":["3-5 个短标签","每个不超过 8 个字"]}。' +
  '若图片包含明显文字（截图、文档、海报等），把关键文字一并写入 summary。';

const GROUP_BOT_INTRO = `你正在帮一个机器人写"何时叫我"说明,挂在群聊调度器查得到的位置。要求:
- 中文,1-2 句话,不超过 80 字
- 写"我适合什么话题/什么场景被叫出来发言"
- 不要写客套话,不要写自我介绍,直接说话题
- 不要透露自己用什么模型`;

const OUTPUT_MODE_BUBBLE =
  '## 输出模式：bubble\n你的回复以微信气泡风格切分。每段独立成义，使用 `\\n---\\n` 分隔每个气泡。短而自然，避免段落式长句。';

const OUTPUT_MODE_SINGLE =
  '## 输出模式：single\n你的回复是一段连续的文本。不要使用气泡分隔符。可以用换行做正常排版。';

// name → body. `name` here is the bare PromptName; the Langfuse name appends
// `/<locale>`.
const PROMPTS = {
  'lookback-instruction': LOOKBACK_INSTRUCTION,
  'image-summary': IMAGE_SUMMARY,
  'group-bot-intro': GROUP_BOT_INTRO,
  'output-mode-bubble': OUTPUT_MODE_BUBBLE,
  'output-mode-single': OUTPUT_MODE_SINGLE,
};

// ── .dev.vars loader (mirrors seed-public-skills.mjs) ──────────────────────
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
const PUBLIC_KEY = env.LANGFUSE_PUBLIC_KEY;
const SECRET_KEY = env.LANGFUSE_SECRET_KEY;
const BASE_URL = (env.LANGFUSE_BASE_URL || 'https://cloud.langfuse.com').replace(/\/+$/, '');
if (!PUBLIC_KEY || !SECRET_KEY) {
  console.error('missing LANGFUSE_PUBLIC_KEY or LANGFUSE_SECRET_KEY in .dev.vars');
  process.exit(1);
}

// Langfuse public API uses HTTP Basic auth: publicKey as user, secretKey as pass.
const authHeader = `Basic ${Buffer.from(`${PUBLIC_KEY}:${SECRET_KEY}`).toString('base64')}`;

let created = 0;
let failed = 0;
for (const [name, body] of Object.entries(PROMPTS)) {
  const langfuseName = `${name}/${LOCALE}`;
  const res = await fetch(`${BASE_URL}/api/public/v2/prompts`, {
    method: 'POST',
    headers: {
      Authorization: authHeader,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      type: 'text',
      name: langfuseName,
      prompt: body,
      labels: [PRODUCTION_LABEL],
    }),
  });
  if (!res.ok) {
    failed++;
    console.error(
      `create ${langfuseName} failed: ${res.status} ${(await res.text()).slice(0, 300)}`,
    );
    continue;
  }
  const json = await res.json().catch(() => ({}));
  created++;
  console.log(`ok ${langfuseName} → version ${json.version ?? '?'} (labels: ${(json.labels ?? []).join(',')})`);
}

console.log(`done. created=${created} failed=${failed}`);
if (failed > 0) process.exit(1);
