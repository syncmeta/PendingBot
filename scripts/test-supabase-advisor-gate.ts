import { strict as assert } from 'node:assert';
import { readFileSync } from 'node:fs';
import { evaluateAdvisorGate } from './supabase-advisor-gate';

type AdvisorFile = { result?: { lints?: unknown[] }; lints?: unknown[] } | unknown[];

function loadJson<T>(path: string): T {
  return JSON.parse(readFileSync(path, 'utf8')) as T;
}

function lintsFrom(path: string): unknown[] {
  const parsed = loadJson<AdvisorFile>(path);
  if (Array.isArray(parsed)) return parsed;
  return parsed.result?.lints ?? parsed.lints ?? [];
}

const allowlist = loadJson('docs/supabase-advisor-allowlist.json');

const allowed = evaluateAdvisorGate(
  allowlist as Parameters<typeof evaluateAdvisorGate>[0],
  lintsFrom('scripts/fixtures/supabase-advisor-allowed.json') as Parameters<
    typeof evaluateAdvisorGate
  >[1],
  new Date('2026-05-25T00:00:00Z'),
);
assert.equal(allowed.blocked.length, 0, 'allowlisted fixture should not block');
assert.equal(allowed.allowed.length, 1, 'allowlisted fixture should record one allowed lint');

const blocked = evaluateAdvisorGate(
  allowlist as Parameters<typeof evaluateAdvisorGate>[0],
  lintsFrom('scripts/fixtures/supabase-advisor-blocked.json') as Parameters<
    typeof evaluateAdvisorGate
  >[1],
  new Date('2026-05-25T00:00:00Z'),
);
assert.equal(blocked.allowed.length, 0, 'blocked fixture should not be allowed');
assert.equal(blocked.blocked.length, 1, 'blocked fixture should fail closed');
assert.equal(
  blocked.blocked[0]?.lint.cache_key,
  'auth_leaked_password_protection',
  'blocked fixture should preserve the advisor cache key',
);

console.log('Supabase advisor gate fixture tests passed.');
