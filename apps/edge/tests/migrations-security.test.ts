import { describe, expect, it } from 'vitest';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const repoRoot = join(import.meta.dirname, '..', '..', '..');

function readMigration(path: string): string {
  return readFileSync(join(repoRoot, path), 'utf8');
}

function readAllMigrations(): string {
  const dir = join(repoRoot, 'supabase/migrations');
  return readdirSync(dir)
    .filter((file) => file.endsWith('.sql'))
    .sort()
    .map((file) => readFileSync(join(dir, file), 'utf8'))
    .join('\n\n');
}

describe('security-sensitive migrations', () => {
  it('persists skipped group-billing split states so future payer scans can exclude them', () => {
    const sql = readAllMigrations();

    expect(sql).toMatch(/skipped_overdrawn/);
    expect(sql).toMatch(/skipped_capped/);
    expect(sql).toMatch(/overdrawn\s*=\s*true/i);
  });

  it('revokes exposed definer RPC execution from anon and keeps service-only billing internals private', () => {
    const sql = readMigration('supabase/migrations/20260524175632_harden_function_execute_privileges.sql');

    expect(sql).toMatch(/alter\s+default\s+privileges[\s\S]+revoke\s+execute\s+on\s+functions\s+from\s+anon,\s*authenticated,\s*public/i);
    expect(sql).toMatch(/revoke\s+execute\s+on\s+all\s+functions\s+in\s+schema\s+pendingbot\s+from\s+anon,\s*public/i);
    expect(sql).toMatch(/revoke\s+execute\s+on\s+function\s+pendingbot\.billing_admin_grant\(uuid,\s*bigint,\s*text\)\s+from\s+authenticated/i);
    expect(sql).toMatch(/grant\s+execute\s+on\s+function\s+pendingbot\.billing_admin_grant\(uuid,\s*bigint,\s*text\)\s+to\s+service_role/i);
  });

  it('keeps chat attachment metadata scoped to non-deleted message references', () => {
    const sql = readMigration('supabase/migrations/20260524175919_tighten_attachment_read_policy.sql');

    expect(sql).toMatch(/drop\s+policy\s+if\s+exists\s+attachments_self_read/i);
    expect(sql).toMatch(/m\.status\s*<>\s*'deleted'/i);
    expect(sql).toMatch(/m\.attachments\s*->\s*'ids'\s*\?\s*attachments\.id::text/i);
    expect(sql).toMatch(/pendingbot\.is_participant\(m\.conversation_id\)/i);
  });
});
