import { strict as assert } from 'node:assert';
import { readFileSync } from 'node:fs';
import { evaluateDefinerGate, rowsFrom, signatureOf, type Allowlist } from './definer-execute-gate';

function load<T>(path: string): T {
  return JSON.parse(readFileSync(path, 'utf8')) as T;
}

const NOW = new Date('2026-08-21T00:00:00Z');
const shipped = load<Allowlist>('docs/definer-execute-allowlist.json');
const red = rowsFrom(load('scripts/fixtures/definer-execute-offending.json'));
const yellow = rowsFrom(load('scripts/fixtures/definer-execute-unbound.json'));
const clean = rowsFrom(load('scripts/fixtures/definer-execute-clean.json'));

// --- the shipped allowlist's own invariants -------------------------------

// Red never gets an exemption: an entry would mean unauthenticated callers may
// run privileged, RLS-bypassing code.
assert.equal(
  shipped.allowed_definer_functions.length,
  0,
  'allowed_definer_functions must stay empty — no anon/PUBLIC definer function is ever acceptable',
);

// Yellow may carry entries, but a registration is only worth anything if it
// says why and comes back. Both are enforced, not conventions.
for (const entry of shipped.registered_unbound_definer_functions ?? []) {
  assert.ok(
    entry.reason && entry.reason.length > 40,
    `${entry.signature}: a registration needs a real written reason, not a placeholder`,
  );
  assert.ok(
    entry.expires_on,
    `${entry.signature}: a registration must expire, otherwise it is a permanent hole with paperwork`,
  );
}

// --- red -------------------------------------------------------------------

const caughtRed = evaluateDefinerGate(shipped, red, NOW);
assert.equal(caughtRed.blocked.length, 1, 'anon-executable definer function must block');
assert.equal(caughtRed.blocked[0]?.severity, 'red');
assert.equal(
  caughtRed.blocked[0]?.signature,
  'pendingbot.upsert_self_machine(p_subject_id uuid, p_device_id text, p_display_name text)',
  'the report must name the offending signature',
);

// A row with no severity column (older audit output) is treated as red, not skipped.
const legacyShape = evaluateDefinerGate(
  shipped,
  [{ schema: 'pendingbot', function: 'legacy', args: '', anon_execute: true }],
  NOW,
);
assert.equal(legacyShape.blocked[0]?.severity, 'red', 'severity-less rows must fail closed as red');

// PUBLIC-only grants (anon revoked separately) still count.
const publicOnly = evaluateDefinerGate(
  shipped,
  [{ severity: 'red', schema: 'public', function: 'f', args: '', anon_execute: false, public_execute: true }],
  NOW,
);
assert.equal(publicOnly.blocked.length, 1, 'PUBLIC EXECUTE alone must block');
assert.match(publicOnly.blocked[0]!.reason, /PUBLIC/, 'reason should name PUBLIC');

// --- yellow ----------------------------------------------------------------

// Unregistered yellow blocks: "authenticated only" is not a pass.
const unregistered = evaluateDefinerGate(shipped, yellow, NOW);
assert.equal(unregistered.blocked.length, 1, 'unregistered unbound definer function must block');
assert.equal(unregistered.blocked[0]?.severity, 'yellow');
assert.match(unregistered.blocked[0]!.reason, /auth\.uid\(\)/, 'reason should say what is missing');

// Registered yellow passes — but is reported, not swallowed.
const registered = load<Allowlist>('scripts/fixtures/definer-execute-allowlisted.json');
const withinWindow = evaluateDefinerGate(registered, yellow, new Date('2026-09-01T00:00:00Z'));
assert.equal(withinWindow.blocked.length, 0, 'registered yellow should not block');
assert.equal(withinWindow.allowed.length, 1, 'registered yellow must still be reported');
assert.equal(withinWindow.allowed[0]?.severity, 'yellow');

// ...and comes back when the registration expires.
const afterExpiry = evaluateDefinerGate(registered, yellow, new Date('2026-10-01T00:00:00Z'));
assert.equal(afterExpiry.blocked.length, 1, 'expired registration must stop suppressing');
assert.match(afterExpiry.blocked[0]!.reason, /expired/, 'expiry must be stated in the reason');

// The two allowlists are not interchangeable: a red signature registered in the
// yellow section must not let the red finding through.
const crossed: Allowlist = {
  version: 2,
  reviewed_at: 'test',
  allowed_definer_functions: [],
  registered_unbound_definer_functions: [
    { signature: signatureOf(red[0]!), reason: 'x'.repeat(50), expires_on: '2027-01-01' },
  ],
};
assert.equal(
  evaluateDefinerGate(crossed, red, NOW).blocked.length,
  1,
  'a yellow registration must not suppress a red finding',
);

// --- misc ------------------------------------------------------------------

assert.equal(evaluateDefinerGate(shipped, clean, NOW).blocked.length, 0, 'no rows means nothing to block');
assert.deepEqual(rowsFrom([]), []);
assert.equal(signatureOf({ schema: 's', function: 'f', args: 'a int' }), 's.f(a int)');

console.log('Definer execute gate fixture tests passed.');
