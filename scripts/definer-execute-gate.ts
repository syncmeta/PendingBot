import { readFileSync } from 'node:fs';

/**
 * Fail CI when a SECURITY DEFINER function in a PostgREST-exposed schema is
 * executable by `anon` or by PUBLIC.
 *
 * Such a function runs as the database owner and bypasses RLS, so a PUBLIC
 * EXECUTE grant turns it into an unauthenticated write/read endpoint at
 * /rest/v1/rpc/<name>. Postgres grants EXECUTE to PUBLIC by default, which
 * means the failure mode is *forgetting* a REVOKE, not writing a wrong GRANT —
 * the kind of thing that recurs until a machine checks for it. It already
 * recurred once: the 2026-05 hardening pass, then `upsert_self_machine` in
 * 2026-08.
 *
 * Input is the JSON output of `scripts/sql/definer-execute-audit.sql`
 * (`supabase db query -o json -f ...`), read from a path or from stdin.
 */

export interface DefinerRow {
  schema: string;
  function: string;
  args: string;
  anon_execute?: boolean;
  public_execute?: boolean;
  anon_schema_usage?: boolean;
  acl?: string;
}

interface AllowEntry {
  /** `schema.function(identity args)` — exactly as the audit query reports it. */
  signature: string;
  reason: string;
  expires_on?: string;
}

export interface Allowlist {
  version: number;
  reviewed_at: string;
  allowed_definer_functions: AllowEntry[];
}

export interface Finding {
  row: DefinerRow;
  signature: string;
  reason: string;
}

export function signatureOf(row: DefinerRow): string {
  return `${row.schema}.${row.function}(${row.args ?? ''})`;
}

function isExpired(entry: AllowEntry, today: Date): boolean {
  if (!entry.expires_on) return false;
  const expiry = new Date(`${entry.expires_on}T23:59:59Z`);
  return Number.isFinite(expiry.getTime()) && expiry < today;
}

export function evaluateDefinerGate(
  allowlist: Allowlist,
  rows: DefinerRow[],
  today = new Date(),
): { allowed: Finding[]; blocked: Finding[] } {
  const allowed: Finding[] = [];
  const blocked: Finding[] = [];
  const entries = new Map(
    (allowlist.allowed_definer_functions ?? []).map((entry) => [entry.signature, entry]),
  );

  for (const row of rows) {
    const signature = signatureOf(row);
    const why = row.anon_execute
      ? 'anon can EXECUTE this SECURITY DEFINER function'
      : 'PUBLIC holds EXECUTE on this SECURITY DEFINER function';
    const entry = entries.get(signature);

    if (entry && !isExpired(entry, today)) {
      allowed.push({ row, signature, reason: entry.reason });
    } else {
      blocked.push({
        row,
        signature,
        reason: entry ? `${why} — allowlist entry expired` : why,
      });
    }
  }

  return { allowed, blocked };
}

export function rowsFrom(parsed: unknown): DefinerRow[] {
  if (Array.isArray(parsed)) return parsed as DefinerRow[];
  if (parsed && typeof parsed === 'object' && Array.isArray((parsed as { rows?: unknown }).rows)) {
    return (parsed as { rows: DefinerRow[] }).rows;
  }
  throw new Error('unrecognised audit JSON: expected an array or an object with a `rows` array');
}

function usage(): never {
  console.error(
    'Usage: bun scripts/definer-execute-gate.ts --allowlist docs/definer-execute-allowlist.json [<audit-json> | -]',
  );
  console.error('Produce <audit-json> with:');
  console.error('  supabase db query --local  -o json -f scripts/sql/definer-execute-audit.sql');
  console.error('  supabase db query --linked -o json -f scripts/sql/definer-execute-audit.sql');
  process.exit(2);
}

async function main() {
  const args = process.argv.slice(2);
  const allowIdx = args.indexOf('--allowlist');
  if (allowIdx < 0 || !args[allowIdx + 1]) usage();
  const allowlistPath = args[allowIdx + 1];
  const inputs = args.filter((_, idx) => idx !== allowIdx && idx !== allowIdx + 1);
  const source = inputs[0] ?? '-';

  const raw = source === '-' ? await Bun.stdin.text() : readFileSync(source, 'utf8');
  const rows = rowsFrom(JSON.parse(raw));
  const allowlist = JSON.parse(readFileSync(allowlistPath, 'utf8')) as Allowlist;
  const result = evaluateDefinerGate(allowlist, rows);

  for (const finding of result.allowed) {
    console.log(`ALLOW ${finding.signature} - ${finding.reason}`);
  }
  for (const finding of result.blocked) {
    console.error(`BLOCK ${finding.signature} - ${finding.reason}`);
    if (finding.row.acl) console.error(`  acl: ${finding.row.acl}`);
    console.error(
      '  fix: add `revoke execute on function <sig> from public, anon, authenticated;`' +
        ' to the migration that creates it, and self-authorize in the body against auth.uid()' +
        ' (see 20260820073931_revoke_public_execute_upsert_self_machine.sql).',
    );
  }

  if (result.blocked.length > 0) process.exit(1);
  console.log(
    `Definer execute gate passed (${rows.length} row(s) inspected, ${result.allowed.length} allowlisted).`,
  );
}

if (import.meta.main) await main();
