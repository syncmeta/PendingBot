import { strict as assert } from 'node:assert';
import { readFileSync } from 'node:fs';
import { evaluateDefinerGate, rowsFrom, signatureOf, type Allowlist } from './definer-execute-gate';

function load<T>(path: string): T {
  return JSON.parse(readFileSync(path, 'utf8')) as T;
}

const realAllowlist = load<Allowlist>('docs/definer-execute-allowlist.json');
const offending = rowsFrom(load('scripts/fixtures/definer-execute-offending.json'));
const clean = rowsFrom(load('scripts/fixtures/definer-execute-clean.json'));

// The shipped allowlist is empty on purpose: the gate must fail closed.
assert.equal(
  realAllowlist.allowed_definer_functions.length,
  0,
  'docs/definer-execute-allowlist.json should stay empty unless a definer function is deliberately public',
);

// 1) The real hole this gate exists for must be caught.
const caught = evaluateDefinerGate(realAllowlist, offending, new Date('2026-08-20T00:00:00Z'));
assert.equal(caught.blocked.length, 1, 'anon-executable definer function must block');
assert.equal(caught.allowed.length, 0, 'nothing should be allowed with an empty allowlist');
assert.equal(
  caught.blocked[0]?.signature,
  'pendingbot.upsert_self_machine(p_subject_id uuid, p_device_id text, p_display_name text)',
  'the report must name the offending signature',
);

// 2) A clean database passes.
const passed = evaluateDefinerGate(realAllowlist, clean, new Date('2026-08-20T00:00:00Z'));
assert.equal(passed.blocked.length, 0, 'no rows means nothing to block');

// 3) An allowlist entry suppresses the finding only until it expires.
const allowlisted = load<Allowlist>('scripts/fixtures/definer-execute-allowlisted.json');
const withinWindow = evaluateDefinerGate(allowlisted, offending, new Date('2026-09-01T00:00:00Z'));
assert.equal(withinWindow.blocked.length, 0, 'unexpired allowlist entry should suppress');
assert.equal(withinWindow.allowed.length, 1, 'unexpired allowlist entry should be reported as allowed');

const afterExpiry = evaluateDefinerGate(allowlisted, offending, new Date('2026-10-01T00:00:00Z'));
assert.equal(afterExpiry.blocked.length, 1, 'expired allowlist entry must stop suppressing');
assert.match(afterExpiry.blocked[0]!.reason, /expired/, 'expiry must be stated in the reason');

// 4) PUBLIC-only grants (anon revoked separately) still count.
const publicOnly = evaluateDefinerGate(
  realAllowlist,
  [{ schema: 'public', function: 'f', args: '', anon_execute: false, public_execute: true }],
  new Date('2026-08-20T00:00:00Z'),
);
assert.equal(publicOnly.blocked.length, 1, 'PUBLIC EXECUTE alone must block');
assert.match(publicOnly.blocked[0]!.reason, /PUBLIC/, 'reason should name PUBLIC');

// 5) Both audit JSON shapes are accepted.
assert.deepEqual(rowsFrom([]), []);
assert.equal(signatureOf({ schema: 's', function: 'f', args: 'a int' }), 's.f(a int)');

console.log('Definer execute gate fixture tests passed.');
