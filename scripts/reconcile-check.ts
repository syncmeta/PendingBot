/**
 * reconcile-check — fail-loud assertion layer for the declarative-reconciliation
 * doc system (see docs/handbook/pendingcrew/concepts/reconciliation.md).
 *
 * Asserts lightweight invariants between the 期望 handbook (docs/handbook/, pure
 * intent) and the 现状 mirror (docs/state/, structured status). Reports only;
 * never edits the books ("只报错、不自动改账"). This is the data-layer floor the
 * cockpit (#439) renders on top of.
 *
 * Invariants:
 *   - missing-state-entry   handbook page with no matching 现状 entry
 *   - orphan-state-entry    现状 entry with no matching handbook page
 *                           (## stack/* keys exempt where stackCoarse: shared.md
 *                            carries a curated per-service stack mirror, not 1:1)
 *   - malformed-state-entry 现状 entry missing one of status/现状/证据/task
 *   - bad-status            status: value not in {planned,partial,done}[, pending-qa]
 *   - expectation-has-status 期望 page still carries a 现状 status section
 *                            (enforced per-area via enforcePurity, flipped on as
 *                             each area's sweep lands)
 *
 * Pattern mirrors scripts/supabase-advisor-gate.ts (pure evaluate fn + allowlist).
 */
import { readFileSync, readdirSync, existsSync } from 'node:fs';

// ---- pure parsing --------------------------------------------------------

export interface StateEntry {
  key: string;
  status: string | null;
  fields: Set<string>;
  task?: string;
}

const STATE_FIELDS = ['status', '现状', '证据', 'task'] as const;

/** Parse a docs/state/<area>.md file into its `## <key>` entries. */
export function parseStateEntries(content: string): StateEntry[] {
  const entries: StateEntry[] = [];
  let current: StateEntry | null = null;
  for (const line of content.split('\n')) {
    const heading = line.match(/^##\s+(.+?)\s*$/);
    if (heading) {
      if (current) entries.push(current);
      current = { key: heading[1], status: null, fields: new Set() };
      continue;
    }
    if (!current) continue;
    const field = line.match(/^(status|现状|证据|task)\s*[:：]\s*(.*)$/);
    if (field) {
      current.fields.add(field[1]);
      if (field[1] === 'status') current.status = field[2].trim();
      if (field[1] === 'task') current.task = field[2].trim();
    }
  }
  if (current) entries.push(current);
  return entries;
}

/** True if a 期望 handbook page still carries a 现状 status section. */
export function pageHasStatusSection(content: string): boolean {
  return /^##\s*现状(?:\s|$)/m.test(content) || /^\*\*现状\*\*/m.test(content);
}

/** Valid `status:` enum: planned | partial | done, optionally `, pending-qa`. */
export function isValidStatus(status: string): boolean {
  return /^(planned|partial|done)(,\s*pending-qa)?$/.test(status.trim());
}

// ---- task files ----------------------------------------------------------

export interface Task {
  id: string;
  status: string;
  expects: string[];
  state: string[];
  deps: string[];
}

const TASK_STATUS = ['todo', 'doing', 'pending-qa', 'done', 'dropped'];

function parseList(value: string): string[] {
  const inner = value.trim().replace(/^\[/, '').replace(/\]$/, '').trim();
  return inner ? inner.split(',').map((s) => s.trim()).filter(Boolean) : [];
}

/** Parse a docs/tasks/<id>.md frontmatter into a Task. */
export function parseTaskFile(content: string): Task {
  const fm = content.match(/^---\n([\s\S]*?)\n---/);
  const body = fm ? fm[1] : '';
  const get = (key: string): string => {
    const m = body.match(new RegExp(`^${key}\\s*:\\s*(.*)$`, 'm'));
    return m ? m[1].trim() : '';
  };
  return {
    id: get('id'),
    status: get('status'),
    expects: parseList(get('expects')),
    state: parseList(get('state')),
    deps: parseList(get('deps')),
  };
}

/** Pull new-ledger task ids (yyyymmdd-xx) out of a 现状 `task:` value; ignores #NNN / Tx.y. */
export function extractTaskIds(value: string): string[] {
  return [...value.matchAll(/\b\d{8}-[a-z0-9]{2}\b/g)].map((m) => m[0]);
}

// ---- pure evaluation -----------------------------------------------------

export interface Area {
  name: string;
  handbookRelpaths: string[];
  pagesWithStatusSection: string[];
  stateEntries: StateEntry[];
  enforcePurity: boolean;
  stackCoarse: boolean;
}

export interface Violation {
  code: string;
  area: string;
  detail: string;
}

export interface AllowEntry {
  key: string;
  reason: string;
  expires_on?: string;
}

export function violationKey(v: Violation): string {
  return `${v.code}:${v.area}:${v.detail}`;
}

function isExpired(entry: AllowEntry, today: Date): boolean {
  if (!entry.expires_on) return false;
  const expiry = new Date(`${entry.expires_on}T23:59:59Z`);
  return Number.isFinite(expiry.getTime()) && expiry < today;
}

export function collectViolations(areas: Area[], tasks: Task[] = []): Violation[] {
  const out: Violation[] = [];
  for (const a of areas) {
    const handbookSet = new Set(a.handbookRelpaths);
    const stateSet = new Set(a.stateEntries.map((e) => e.key));

    for (const rel of a.handbookRelpaths) {
      if (!stateSet.has(rel)) out.push({ code: 'missing-state-entry', area: a.name, detail: rel });
    }
    for (const e of a.stateEntries) {
      if (handbookSet.has(e.key)) continue;
      if (a.stackCoarse && e.key.startsWith('stack/')) continue;
      out.push({ code: 'orphan-state-entry', area: a.name, detail: e.key });
    }
    for (const e of a.stateEntries) {
      const missing = STATE_FIELDS.filter((f) => !e.fields.has(f));
      if (missing.length > 0) {
        out.push({ code: 'malformed-state-entry', area: a.name, detail: `${e.key} (missing ${missing.join('/')})` });
      } else if (e.status === null || !isValidStatus(e.status)) {
        out.push({ code: 'bad-status', area: a.name, detail: `${e.key} (status=${e.status ?? '∅'})` });
      }
    }
    if (a.enforcePurity) {
      for (const rel of a.pagesWithStatusSection) {
        out.push({ code: 'expectation-has-status', area: a.name, detail: rel });
      }
    }
  }

  // ---- cross-ledger: task ↔ 期望 / 现状 / deps ----
  const handbookPages = new Set(areas.flatMap((a) => a.handbookRelpaths.map((r) => `${a.name}/${r}`)));
  const stateKeys = new Set(areas.flatMap((a) => a.stateEntries.map((e) => `${a.name}/${e.key}`)));
  const taskIds = new Set(tasks.map((t) => t.id));

  for (const t of tasks) {
    for (const ref of t.expects) {
      if (!handbookPages.has(ref)) out.push({ code: 'task-expects-missing', area: 'tasks', detail: `${t.id} → ${ref}` });
    }
    for (const ref of t.state) {
      if (!stateKeys.has(ref)) out.push({ code: 'task-state-missing', area: 'tasks', detail: `${t.id} → ${ref}` });
    }
    for (const dep of t.deps) {
      if (!taskIds.has(dep)) out.push({ code: 'task-dep-missing', area: 'tasks', detail: `${t.id} → ${dep}` });
    }
    if (!TASK_STATUS.includes(t.status)) out.push({ code: 'bad-task-status', area: 'tasks', detail: `${t.id} (status=${t.status || '∅'})` });
  }

  // reverse: 现状条 task: 引用的新账本 id 必须解析到 task 文件(#NNN / Tx.y 豁免)
  for (const a of areas) {
    for (const e of a.stateEntries) {
      for (const id of extractTaskIds(e.task ?? '')) {
        if (!taskIds.has(id)) out.push({ code: 'state-task-missing', area: a.name, detail: `${e.key} → ${id}` });
      }
    }
  }

  return out;
}

export function evaluateReconcile(
  areas: Area[],
  allow: AllowEntry[],
  today = new Date(),
  tasks: Task[] = [],
): { blocked: Violation[]; allowed: { v: Violation; reason: string }[] } {
  const allowMap = new Map(allow.map((e) => [e.key, e]));
  const blocked: Violation[] = [];
  const allowed: { v: Violation; reason: string }[] = [];
  for (const v of collectViolations(areas, tasks)) {
    const entry = allowMap.get(violationKey(v));
    if (entry && !isExpired(entry, today)) allowed.push({ v, reason: entry.reason });
    else blocked.push(v);
  }
  return { blocked, allowed };
}

// ---- filesystem wiring (main) -------------------------------------------

interface AreaConfig {
  name: string;
  handbookDir: string;
  stateFile: string;
  enforcePurity: boolean;
  stackCoarse: boolean;
}

/**
 * enforcePurity flips to true once an area's 现状-section sweep has landed.
 * pendingcrew: swept 2026-06-26. pendingbot/shared: sweep pending (separate task).
 */
const AREAS: AreaConfig[] = [
  { name: 'pendingbot', handbookDir: 'docs/handbook/pendingbot', stateFile: 'docs/state/pendingbot.md', enforcePurity: false, stackCoarse: false },
  { name: 'pendingcrew', handbookDir: 'docs/handbook/pendingcrew', stateFile: 'docs/state/pendingcrew.md', enforcePurity: true, stackCoarse: false },
  { name: 'shared', handbookDir: 'docs/handbook/shared', stateFile: 'docs/state/shared.md', enforcePurity: false, stackCoarse: true },
];

function handbookRelpaths(dir: string): string[] {
  if (!existsSync(dir)) return [];
  return readdirSync(dir, { recursive: true })
    .map(String)
    .filter((p) => p.endsWith('.md'))
    .map((p) => p.replace(/\.md$/, ''))
    .sort();
}

function buildArea(cfg: AreaConfig): Area {
  const relpaths = handbookRelpaths(cfg.handbookDir);
  const pagesWithStatusSection = relpaths.filter((rel) =>
    pageHasStatusSection(readFileSync(`${cfg.handbookDir}/${rel}.md`, 'utf8')),
  );
  const stateEntries = existsSync(cfg.stateFile)
    ? parseStateEntries(readFileSync(cfg.stateFile, 'utf8'))
    : [];
  return {
    name: cfg.name,
    handbookRelpaths: relpaths,
    pagesWithStatusSection,
    stateEntries,
    enforcePurity: cfg.enforcePurity,
    stackCoarse: cfg.stackCoarse,
  };
}

function loadAllowlist(path: string | undefined): AllowEntry[] {
  if (!path) return [];
  if (!existsSync(path)) return [];
  const parsed = JSON.parse(readFileSync(path, 'utf8')) as { allowed?: AllowEntry[] } | AllowEntry[];
  return Array.isArray(parsed) ? parsed : parsed.allowed ?? [];
}

function loadTasks(dir: string): Task[] {
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .map(String)
    .filter((f) => f.endsWith('.md') && f !== 'README.md')
    .map((f) => parseTaskFile(readFileSync(`${dir}/${f}`, 'utf8')));
}

function main() {
  const args = process.argv.slice(2);
  const allowIdx = args.indexOf('--allowlist');
  const allowlistPath = allowIdx >= 0 ? args[allowIdx + 1] : 'docs/reconcile-allowlist.json';

  const areas = AREAS.map(buildArea);
  const tasks = loadTasks('docs/tasks');
  const allow = loadAllowlist(allowlistPath);
  const { blocked, allowed } = evaluateReconcile(areas, allow, new Date(), tasks);

  for (const { v, reason } of allowed) {
    console.log(`ALLOW ${v.code} ${v.area}/${v.detail} — ${reason}`);
  }
  for (const v of blocked) {
    console.error(`BLOCK ${v.code} ${v.area}/${v.detail}`);
  }

  if (blocked.length > 0) {
    console.error(`\nreconcile-check failed: ${blocked.length} unallowed violation(s).`);
    process.exit(1);
  }
  console.log(`reconcile-check passed (${areas.length} areas, ${tasks.length} tasks, ${allowed.length} allowlisted).`);
}

if (import.meta.main) main();
