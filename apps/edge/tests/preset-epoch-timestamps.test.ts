import { describe, expect, it } from 'vitest';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

// The preset conversations are deliberately stamped in the epoch year — the
// date badge is a designed marker, not a stale timestamp. This suite pins the
// invariants that keep the marker readable and the seeded rows separable from
// real user replies:
//
//   1. the base-timestamp literal lives in exactly one place (a SQL
//      constant function) so moving it stays a one-value edit;
//   2. the preseeded-vs-real-reply criterion sits strictly above that base
//      (the old `< 1970-01-02` boundary would classify the new stamps as real
//      replies);
//   3. the per-slug offsets keep the conversation-list order the old
//      hour-spaced bases produced, and stay inside the same 12:34 minute so
//      every preset conversation renders the same wall-clock time.
//
// The stamp is not timezone-locked for display: 12:34 is what a UTC+8 screen
// reads, which is the screen the marker was designed for.

const repoRoot = join(import.meta.dirname, '..', '..', '..');
const migrationsDir = join(repoRoot, 'supabase/migrations');

function migrationPath(suffix: string): string {
  const file = readdirSync(migrationsDir)
    .filter((name) => name.endsWith(suffix))
    .sort()
    .at(-1);
  if (!file) throw new Error(`no migration ending in ${suffix}`);
  return join(migrationsDir, file);
}

const epochMigration = readFileSync(migrationPath('_preset_epoch_1970_01_02.sql'), 'utf8');
const boardPresets = readFileSync(
  join(migrationsDir, '20260523102129_board_presets.sql'),
  'utf8',
);

// 1970-01-02 12:34 Beijing time — the clock the product shows on a UTC+8
// device. Stored in UTC, which is where the 04:34 comes from.
const BASE_LITERAL = '1970-01-02 04:34:00+00';

/** slug → seconds-after-midnight of the base_ts seeded by 20260523102129. */
function oldConversationBases(): Map<string, number> {
  const out = new Map<string, number>();
  const re = /\('([a-z]+)',\s*'[a-z]+',\s*'[^']*',\s*'1970-01-01 (\d{2}):(\d{2}):00\+00'/g;
  for (const m of boardPresets.matchAll(re)) {
    out.set(m[1], Number(m[2]) * 3600 + Number(m[3]) * 60);
  }
  return out;
}

/** slug → offset in seconds after the new base, parsed from the new migration. */
function newOffsets(): Map<string, number> {
  const block = epochMigration.match(
    /preset_epoch_offsets[\s\S]*?values([\s\S]*?)\)\s*as\s+t\s*\(/i,
  );
  if (!block) throw new Error('no preset_epoch_offsets values list in the migration');
  const out = new Map<string, number>();
  for (const m of block[1].matchAll(/\('([a-z-]+)',\s*(\d+)\)/g)) {
    out.set(m[1], Number(m[2]));
  }
  return out;
}

/** SQL with `--` comments removed — prose quotes the old boundary on purpose. */
function code(sql: string): string {
  return sql
    .split('\n')
    .map((line) => line.replace(/--.*$/, ''))
    .join('\n');
}

function countOccurrences(haystack: string, needle: string): number {
  return haystack.split(needle).length - 1;
}

describe('preset epoch timestamps', () => {
  it('keeps the 1970-01-02 12:34 literal in exactly one place', () => {
    const all = readdirSync(migrationsDir)
      .filter((f) => f.endsWith('.sql'))
      .map((f) => readFileSync(join(migrationsDir, f), 'utf8'))
      .join('\n');

    expect(countOccurrences(all, BASE_LITERAL)).toBe(1);
    expect(epochMigration).toMatch(
      new RegExp(
        `function\\s+pendingbot\\.preset_epoch_base_ts\\s*\\(\\s*\\)[\\s\\S]{0,400}${BASE_LITERAL.replace(/[+]/g, '\\+')}`,
        'i',
      ),
    );
  });

  it('pushes the preseeded-vs-real-reply criterion above the new base', () => {
    expect(epochMigration).toMatch(
      /function\s+pendingbot\.preset_epoch_window_end\s*\(\s*\)[\s\S]{0,400}1971-01-01 00:00:00\+00/i,
    );
    // The old boundary would now sit *below* the seeded messages and flip the
    // criterion — it must not survive anywhere in the new migration.
    expect(code(epochMigration)).not.toMatch(/1970-01-02 00:00:00/);
    // Every date comparison in the repair path goes through the constant.
    const comparisons = code(epochMigration).match(/created_at\s*[<>]=?\s*'19\d\d-/g) ?? [];
    expect(comparisons).toEqual([]);
  });

  it('preserves the conversation-list order the hour-spaced bases produced', () => {
    const oldBases = oldConversationBases();
    const offsets = newOffsets();

    const slugs = [...oldBases.keys()];
    expect(slugs.length).toBeGreaterThanOrEqual(6);
    for (const slug of slugs) {
      expect(offsets.has(slug), `missing new offset for preset "${slug}"`).toBe(true);
    }

    const byOld = [...slugs].sort((a, b) => oldBases.get(b)! - oldBases.get(a)!);
    const byNew = [...slugs].sort((a, b) => offsets.get(b)! - offsets.get(a)!);
    expect(byNew).toEqual(byOld);
  });

  it('keeps every preset stamp inside the same 12:34 minute', () => {
    const offsets = [...newOffsets().values()];

    expect(offsets.length).toBeGreaterThan(0);
    for (const offset of offsets) {
      expect(offset).toBeGreaterThanOrEqual(0);
      expect(offset).toBeLessThan(60);
    }
    expect(new Set(offsets).size).toBe(offsets.length);
  });

  it('seeds a dialogue inside its own slot so message count cannot reorder the list', () => {
    // Second-spaced messages would let a longer conversation run past the next
    // slug's slot; sub-second spacing keeps a conversation's last message in
    // the same second as its base.
    const seeder = epochMigration.match(
      /function\s+pendingbot\.seed_sample_dialogue[\s\S]*?\$\$;/i,
    );
    expect(seeder).not.toBeNull();
    expect(seeder![0]).toMatch(/interval\s+'1 millisecond'/i);
    expect(seeder![0]).not.toMatch(/interval\s+'1 second'/i);
  });

  it('restamps rows that were already seeded, cache included', () => {
    expect(epochMigration).toMatch(/update\s+pendingbot\.preset_conversation_templates/i);
    expect(epochMigration).toMatch(/update\s+pendingbot\.messages/i);
    expect(epochMigration).toMatch(/update\s+pendingbot\.user_unread_counts/i);
    expect(epochMigration).toMatch(/preset_epoch_window_end\(\)/);
  });
});
