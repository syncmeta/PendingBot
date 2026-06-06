import { Hono } from 'hono';
import { jsonError } from '../lib/http-error';
import type { AppBindings } from '../types';
import { PROMPT_NAMES, type PromptName } from '../llm/prompt-names';
import { DEFAULT_LOCALE, type Locale } from '../i18n/types';
import { putPromptRecord } from '../llm/prompt-loader';

// Langfuse prompt-version webhook. Langfuse POSTs here when a prompt version
// is created/updated/deleted; we mirror the change into PROMPTS_KV so prompt
// edits go live without a redeploy (read path: llm/prompt-loader.ts).
//
// Auth: HMAC-SHA256 over `${timestamp}.${rawBody}`, sent as
//   x-langfuse-signature: t=<unix>,s=<hex>
// verified against LANGFUSE_WEBHOOK_SECRET in constant time.
//
// We only act on events whose prompt carries the `production` label (that's
// what the worker serves) and whose type is `text`. A label move emits a
// "lost production" event (ignored, no production label) plus a "gained
// production" event (applied), so we don't regress to an older version.

export const langfusePromptRoutes = new Hono<AppBindings>();

const PROMPT_NAME_SET = new Set<string>(PROMPT_NAMES);
const KNOWN_LOCALES = new Set<string>([DEFAULT_LOCALE, 'en']);
const enc = new TextEncoder();

function toHex(buf: ArrayBuffer): string {
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// Verify x-langfuse-signature ("t=<unix>,s=<hexsig>") against the shared
// secret. Signed payload is `${t}.${rawBody}` (HMAC-SHA256).
async function verifySignature(secret: string, header: string, rawBody: string): Promise<boolean> {
  const parts = new Map<string, string>();
  for (const seg of header.split(',')) {
    const eq = seg.indexOf('=');
    if (eq > 0) parts.set(seg.slice(0, eq).trim(), seg.slice(eq + 1).trim());
  }
  const t = parts.get('t');
  const s = parts.get('s');
  if (!t || !s) return false;
  const key = await crypto.subtle.importKey(
    'raw',
    enc.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const mac = await crypto.subtle.sign('HMAC', key, enc.encode(`${t}.${rawBody}`));
  return timingSafeEqual(toHex(mac), s.toLowerCase());
}

langfusePromptRoutes.post('/prompt-webhook', async (c) => {
  const secret = c.env.LANGFUSE_WEBHOOK_SECRET;
  if (!secret) return jsonError(c, 501, 'webhook_not_configured');

  const sig = c.req.header('x-langfuse-signature');
  const raw = await c.req.text();
  if (!sig || !(await verifySignature(secret, sig, raw))) {
    return jsonError(c, 401, 'invalid_signature');
  }

  let body: unknown;
  try {
    body = JSON.parse(raw);
  } catch {
    return jsonError(c, 400, 'invalid_json');
  }

  const p = (body as { prompt?: Record<string, unknown> })?.prompt;
  if (!p || typeof p.name !== 'string') return c.json({ ok: true, ignored: 'no_prompt' });

  const labels = p.labels;
  if (!Array.isArray(labels) || !labels.includes('production')) {
    return c.json({ ok: true, ignored: 'not_production' });
  }
  if (typeof p.type === 'string' && p.type !== 'text') {
    return c.json({ ok: true, ignored: 'not_text' });
  }

  // name is `<promptName>/<locale>`; promptName never contains '/'.
  const name = p.name;
  const slash = name.lastIndexOf('/');
  const promptName = slash >= 0 ? name.slice(0, slash) : name;
  const locale = slash >= 0 ? name.slice(slash + 1) : '';
  if (!PROMPT_NAME_SET.has(promptName) || !KNOWN_LOCALES.has(locale)) {
    return c.json({ ok: true, ignored: 'unknown_name_or_locale' });
  }

  const promptBody = typeof p.prompt === 'string' ? p.prompt : null;
  const version = typeof p.version === 'number' ? p.version : null;
  if (!promptBody || version === null) {
    return c.json({ ok: true, ignored: 'no_body_or_version' });
  }

  await putPromptRecord(c.env, promptName as PromptName, locale as Locale, {
    body: promptBody,
    version,
  });
  return c.json({ ok: true, applied: `${promptName}/${locale}`, version });
});
