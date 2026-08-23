import { readFileSync } from 'node:fs';

/**
 * Two checks over SECURITY DEFINER functions in the PostgREST-exposed schemas.
 * Input is the JSON output of `scripts/sql/definer-execute-audit.sql`
 * (`supabase db query -o json -f ...`), read from a path or from stdin.
 *
 * red    · anon / PUBLIC hold EXECUTE — an unauthenticated, RLS-bypassing
 *          endpoint at /rest/v1/rpc/<name>. Postgres grants EXECUTE to PUBLIC
 *          by default, so this ships by *forgetting* a REVOKE, not by writing a
 *          wrong GRANT. It has happened twice: the 2026-05 hardening batch,
 *          then upsert_self_machine in 2026-08.
 *
 * yellow · `authenticated` holds EXECUTE and nothing on the call path reads
 *          auth.uid() — any logged-in user can aim it at anyone else's id.
 *          Same family: 20260524180643_bind_definer_helpers_to_auth_uid.sql
 *          bound eleven helpers by hand and missed the ones whose parameters
 *          were not named p_user_id.
 *
 * Neither severity is silent. Red must be absent or allowlisted. Yellow must be
 * absent or *registered with a written reason* — and a registered yellow still
 * prints every run, because "someone wrote down why" is not the same as "it was
 * dealt with". Both allowlists carry expiry dates so entries come back.
 *
 * Why yellow is not red: a function can be safe without naming auth.uid()
 * itself, by delegating to a guard that does. The audit SQL resolves that
 * transitively, but the resolution is a heuristic over function bodies, so the
 * finding is "look at this", not "this is broken".
 */

export type Severity = 'red' | 'yellow';

export interface DefinerRow {
  finding?: string;
  severity?: Severity;
  schema: string;
  function: string;
  args: string;
  anon_execute?: boolean;
  authenticated_execute?: boolean;
  public_execute?: boolean;
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
  /** red: anon/PUBLIC may execute this SECURITY DEFINER function on purpose. */
  allowed_definer_functions: AllowEntry[];
  /** yellow: no caller binding, and here is the written reason it is tolerated. */
  registered_unbound_definer_functions?: AllowEntry[];
}

export interface Finding {
  row: DefinerRow;
  signature: string;
  severity: Severity;
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

function severityOf(row: DefinerRow): Severity {
  if (row.severity === 'red' || row.severity === 'yellow') return row.severity;
  // Older audit output carried no severity column: every row was a red finding.
  return 'red';
}

function describe(row: DefinerRow, severity: Severity): string {
  if (severity === 'yellow') {
    return 'authenticated can EXECUTE this SECURITY DEFINER function and nothing on its call path reads auth.uid()';
  }
  return row.anon_execute
    ? 'anon can EXECUTE this SECURITY DEFINER function'
    : 'PUBLIC holds EXECUTE on this SECURITY DEFINER function';
}

export function evaluateDefinerGate(
  allowlist: Allowlist,
  rows: DefinerRow[],
  today = new Date(),
): { allowed: Finding[]; blocked: Finding[] } {
  const allowed: Finding[] = [];
  const blocked: Finding[] = [];
  const byseverity: Record<Severity, Map<string, AllowEntry>> = {
    red: new Map((allowlist.allowed_definer_functions ?? []).map((e) => [e.signature, e])),
    yellow: new Map(
      (allowlist.registered_unbound_definer_functions ?? []).map((e) => [e.signature, e]),
    ),
  };

  for (const row of rows) {
    const severity = severityOf(row);
    const signature = signatureOf(row);
    const why = describe(row, severity);
    const entry = byseverity[severity].get(signature);

    if (entry && !isExpired(entry, today)) {
      allowed.push({ row, signature, severity, reason: entry.reason });
    } else {
      blocked.push({
        row,
        signature,
        severity,
        reason: entry ? `${why} — registration expired` : why,
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

const REMEDY: Record<Severity, string> = {
  red:
    '  fix: add `revoke execute on function <sig> from public, anon, authenticated;` to the migration' +
    ' that creates it, and self-authorize in the body against auth.uid()' +
    ' (see 20260820073931_revoke_public_execute_upsert_self_machine.sql).',
  yellow:
    '  fix: bind it to the caller — `auth.uid() is null or <the id argument> = auth.uid()`, the shape' +
    ' 20260524180643_bind_definer_helpers_to_auth_uid.sql uses — or revoke EXECUTE from authenticated' +
    ' if nothing client-side calls it. If it is genuinely safe (e.g. its caller check lives in a' +
    ' function this heuristic cannot see), register it in the allowlist with the reason and an expiry.',
};

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
    // Registered yellows are still printed loudly: they are outstanding, not settled.
    const label = finding.severity === 'yellow' ? 'WARN ' : 'ALLOW';
    const out = finding.severity === 'yellow' ? console.error : console.log;
    out(`${label} ${finding.signature} - registered: ${finding.reason}`);
  }
  for (const finding of result.blocked) {
    console.error(`BLOCK [${finding.severity}] ${finding.signature} - ${finding.reason}`);
    if (finding.row.acl) console.error(`  acl: ${finding.row.acl}`);
    console.error(REMEDY[finding.severity]);
  }

  if (result.blocked.length > 0) process.exit(1);

  const warned = result.allowed.filter((f) => f.severity === 'yellow').length;
  console.log(
    `Definer execute gate passed (${rows.length} row(s) inspected, ${result.allowed.length} registered` +
      (warned ? `, ${warned} outstanding yellow` : '') +
      ').',
  );
}

if (import.meta.main) await main();
