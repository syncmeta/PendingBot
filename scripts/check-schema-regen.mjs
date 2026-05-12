#!/usr/bin/env node
// Pre-commit guard — if any supabase/migrations/*.sql file is staged,
// apps/edge/src/db/schema.ts MUST also be staged.
//
// Reason: schema.ts is the typescript view of the DB. When migrations
// land without a matching regen, edge code that references the new
// columns/tables either fails to typecheck or papers over with
// `as unknown as` casts. That's how the audit found drift around
// vision_model_override (0064) etc.
//
// Lefthook passes the list of staged files matching the glob as argv.
// We separately ask git for the *all* staged files to check whether
// schema.ts is in the changeset.
//
// Escape hatch: LEFTHOOK=0 git commit ...

import { execSync } from 'node:child_process';

const migrationFiles = process.argv.slice(2);
if (migrationFiles.length === 0) {
  // glob matched nothing in this commit — nothing to guard against
  process.exit(0);
}

const stagedAll = execSync('git diff --cached --name-only', { encoding: 'utf8' })
  .split('\n')
  .filter(Boolean);

const schemaPath = 'apps/edge/src/db/schema.ts';
const schemaStaged = stagedAll.includes(schemaPath);

if (schemaStaged) process.exit(0);

const list = migrationFiles.map((f) => `  - ${f}`).join('\n');
console.error(
  `\n❌ Migration touched but ${schemaPath} not regenerated:\n${list}\n\n` +
    `   Apply the migration (supabase db push --linked from the main worktree),\n` +
    `   then:\n` +
    `       bun --filter='@pendingbot/edge' run types:db\n` +
    `       git add ${schemaPath}\n` +
    `       git commit\n\n` +
    `   To skip this check once (NOT recommended): LEFTHOOK=0 git commit ...\n`,
);
process.exit(1);
