import { strict as assert } from 'node:assert';
import {
  parseStateEntries,
  pageHasStatusSection,
  isValidStatus,
  evaluateReconcile,
  violationKey,
  type Area,
  type StateEntry,
} from './reconcile-check';

// ---- parseStateEntries ---------------------------------------------------

const sample = `> 现状 handbook · pendingcrew 区。镜像期望、每 session 强制刷。

## vision
status: partial
现状: 本地核心可用
证据: 双 build 绿
task: —

## concepts/crew
status: partial, pending-qa
现状: 代码已落
证据: 6 commit 全绿
task: #443(Mac/真机 GUI QA 批次)
`;

const entries = parseStateEntries(sample);
assert.equal(entries.length, 2, 'parses two entries, ignores leading blockquote');
assert.equal(entries[0]?.key, 'vision');
assert.equal(entries[0]?.status, 'partial');
assert.deepEqual([...(entries[0]?.fields ?? [])].sort(), ['status', '现状', '证据', 'task'].sort());
assert.equal(entries[1]?.key, 'concepts/crew');
assert.equal(entries[1]?.status, 'partial, pending-qa');
assert.ok(entries[1]?.fields.has('现状') && entries[1]?.fields.has('证据') && entries[1]?.fields.has('task'));

// ---- pageHasStatusSection ------------------------------------------------

assert.equal(pageHasStatusSection('# T\n**逻辑**\n...\n## 现状\n✅ done\n'), true, 'detects ## 现状 heading');
assert.equal(pageHasStatusSection('# T\n**现状** — 🟨 partial\n- a\n'), true, 'detects **现状** bold block');
assert.equal(pageHasStatusSection('# T\n**逻辑**\n...\n**边界**\n- 不做 X\n'), false, 'pure-intent page has no status section');
assert.equal(pageHasStatusSection('# T\n**注意**\n- ⚠️ 现状别误读\n'), false, 'inline 现状 word in prose is not a status section');

// ---- isValidStatus -------------------------------------------------------

assert.equal(isValidStatus('planned'), true);
assert.equal(isValidStatus('partial'), true);
assert.equal(isValidStatus('done'), true);
assert.equal(isValidStatus('partial, pending-qa'), true);
assert.equal(isValidStatus('done, pending-qa'), true);
assert.equal(isValidStatus('🟨'), false, 'emoji is not a valid status');
assert.equal(isValidStatus('wip'), false, 'unknown enum is invalid');
assert.equal(isValidStatus(''), false);

// ---- evaluateReconcile ---------------------------------------------------

function entry(key: string, opts: { status?: string; drop?: string } = {}): StateEntry {
  const fields = new Set(['status', '现状', '证据', 'task']);
  if (opts.drop) fields.delete(opts.drop);
  return { key, status: opts.status ?? 'partial', fields };
}

function area(over: Partial<Area> = {}): Area {
  return {
    name: 'pc',
    handbookRelpaths: ['vision', 'concepts/crew'],
    pagesWithStatusSection: [],
    stateEntries: [entry('vision'), entry('concepts/crew')],
    enforcePurity: true,
    stackCoarse: false,
    ...over,
  };
}

// clean area → no violations
assert.equal(evaluateReconcile([area()], []).blocked.length, 0, 'clean area passes');

// missing mirror: handbook page with no state entry
const missing = evaluateReconcile(
  [area({ handbookRelpaths: ['vision', 'concepts/crew', 'concepts/captain'] })],
  [],
);
assert.equal(missing.blocked.length, 1);
assert.equal(missing.blocked[0]?.code, 'missing-state-entry');
assert.equal(missing.blocked[0]?.detail, 'concepts/captain');

// orphan state entry: state entry with no handbook page
const orphan = evaluateReconcile(
  [area({ stateEntries: [entry('vision'), entry('concepts/crew'), entry('concepts/ghost')] })],
  [],
);
assert.equal(orphan.blocked.length, 1);
assert.equal(orphan.blocked[0]?.code, 'orphan-state-entry');
assert.equal(orphan.blocked[0]?.detail, 'concepts/ghost');

// stackCoarse: ## stack/* state keys are exempt from 1:1 orphan check
const stackArea = evaluateReconcile(
  [
    area({
      stateEntries: [entry('vision'), entry('concepts/crew'), entry('stack/cloudflare'), entry('stack/apple')],
      stackCoarse: true,
    }),
  ],
  [],
);
assert.equal(stackArea.blocked.length, 0, 'stack/* coarse keys are not flagged as orphans when stackCoarse');

// malformed entry: missing a required field
const malformed = evaluateReconcile([area({ stateEntries: [entry('vision'), entry('concepts/crew', { drop: '证据' })] })], []);
assert.equal(malformed.blocked.length, 1);
assert.equal(malformed.blocked[0]?.code, 'malformed-state-entry');

// bad status value
const badStatus = evaluateReconcile([area({ stateEntries: [entry('vision'), entry('concepts/crew', { status: '🟨 partial' })] })], []);
assert.equal(badStatus.blocked.length, 1);
assert.equal(badStatus.blocked[0]?.code, 'bad-status');

// purity ON: enforced area with a residual status section → violation
const purityOn = evaluateReconcile([area({ pagesWithStatusSection: ['concepts/crew'] })], []);
assert.equal(purityOn.blocked.length, 1);
assert.equal(purityOn.blocked[0]?.code, 'expectation-has-status');
assert.equal(purityOn.blocked[0]?.detail, 'concepts/crew');

// purity OFF: un-swept area does not flag status sections
const purityOff = evaluateReconcile([area({ enforcePurity: false, pagesWithStatusSection: ['concepts/crew'] })], []);
assert.equal(purityOff.blocked.length, 0, 'purity not enforced for un-swept area');

// allowlist: a violation whose key is allowlisted moves to allowed, not blocked
const v = { code: 'missing-state-entry', area: 'pc', detail: 'concepts/captain' };
const allowed = evaluateReconcile(
  [area({ handbookRelpaths: ['vision', 'concepts/crew', 'concepts/captain'] })],
  [{ key: violationKey(v), reason: 'mirror entry pending' }],
);
assert.equal(allowed.blocked.length, 0, 'allowlisted violation does not block');
assert.equal(allowed.allowed.length, 1, 'allowlisted violation is recorded as allowed');

// expired allowlist entry still blocks
const expired = evaluateReconcile(
  [area({ handbookRelpaths: ['vision', 'concepts/crew', 'concepts/captain'] })],
  [{ key: violationKey(v), reason: 'stale', expires_on: '2020-01-01' }],
  new Date('2026-06-26T00:00:00Z'),
);
assert.equal(expired.blocked.length, 1, 'expired allowlist entry no longer suppresses');

console.log('reconcile-check fixture tests passed.');
