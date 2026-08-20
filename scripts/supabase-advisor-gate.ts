import { readFileSync } from 'node:fs';

type LintLevel = 'INFO' | 'WARN' | 'ERROR';

interface AdvisorLint {
  name: string;
  title?: string;
  level: LintLevel | string;
  categories?: string[];
  detail?: string;
  cache_key: string;
}

interface AdvisorFile {
  result?: { lints?: AdvisorLint[] };
  lints?: AdvisorLint[];
}

interface AllowEntry {
  cache_key: string;
  reason: string;
  expires_on?: string;
}

interface Allowlist {
  version: number;
  reviewed_at: string;
  allowed_security_info: AllowEntry[];
  allowed_security_warnings: AllowEntry[];
}

interface Finding {
  lint: AdvisorLint;
  reason: string;
}

function loadJson<T>(path: string): T {
  return JSON.parse(readFileSync(path, 'utf8')) as T;
}

function lintsFrom(path: string): AdvisorLint[] {
  const parsed = loadJson<AdvisorFile | AdvisorLint[]>(path);
  if (Array.isArray(parsed)) return parsed;
  return parsed.result?.lints ?? parsed.lints ?? [];
}

function isSecurity(lint: AdvisorLint): boolean {
  return (lint.categories ?? []).includes('SECURITY');
}

function isExpired(entry: AllowEntry, today = new Date()): boolean {
  if (!entry.expires_on) return false;
  const expiry = new Date(`${entry.expires_on}T23:59:59Z`);
  return Number.isFinite(expiry.getTime()) && expiry < today;
}

export function evaluateAdvisorGate(
  allowlist: Allowlist,
  lints: AdvisorLint[],
  today = new Date(),
): { allowed: Finding[]; blocked: Finding[] } {
  const info = new Map(allowlist.allowed_security_info.map((entry) => [entry.cache_key, entry]));
  const warnings = new Map(allowlist.allowed_security_warnings.map((entry) => [entry.cache_key, entry]));
  const allowed: Finding[] = [];
  const blocked: Finding[] = [];

  for (const lint of lints.filter(isSecurity)) {
    const level = lint.level.toUpperCase();
    if (level === 'INFO') {
      const entry = info.get(lint.cache_key);
      if (entry && !isExpired(entry, today)) {
        allowed.push({ lint, reason: entry.reason });
      } else {
        blocked.push({ lint, reason: entry ? 'allowlist entry expired' : 'security INFO is not allowlisted' });
      }
      continue;
    }

    const entry = warnings.get(lint.cache_key);
    if (entry && !isExpired(entry, today)) {
      allowed.push({ lint, reason: entry.reason });
    } else {
      blocked.push({ lint, reason: entry ? 'allowlist entry expired' : 'security warning is not allowlisted' });
    }
  }

  return { allowed, blocked };
}

function usage(): never {
  console.error('Usage: bun scripts/supabase-advisor-gate.ts --allowlist docs/supabase-advisor-allowlist.json <advisor-json>...');
  process.exit(2);
}

function main() {
  const args = process.argv.slice(2);
  const allowIdx = args.indexOf('--allowlist');
  if (allowIdx < 0 || !args[allowIdx + 1]) usage();
  const allowlistPath = args[allowIdx + 1];
  const advisorPaths = args.filter((arg, idx) => idx !== allowIdx && idx !== allowIdx + 1);
  if (advisorPaths.length === 0) usage();

  const allowlist = loadJson<Allowlist>(allowlistPath);
  const lints = advisorPaths.flatMap(lintsFrom);
  const result = evaluateAdvisorGate(allowlist, lints);

  for (const finding of result.allowed) {
    console.log(`ALLOW ${finding.lint.level} ${finding.lint.cache_key} - ${finding.reason}`);
  }
  for (const finding of result.blocked) {
    console.error(`BLOCK ${finding.lint.level} ${finding.lint.cache_key} - ${finding.reason}`);
    if (finding.lint.detail) console.error(`  ${finding.lint.detail}`);
  }

  if (result.blocked.length > 0) process.exit(1);
  console.log(`Supabase advisor gate passed (${result.allowed.length} security lint(s) allowed).`);
}

if (import.meta.main) main();
