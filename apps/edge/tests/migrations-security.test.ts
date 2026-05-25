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

  it('binds definer helper user parameters to auth.uid for direct authenticated RPC calls', () => {
    const sql = readMigration('supabase/migrations/20260524180643_bind_definer_helpers_to_auth_uid.sql');

    for (const name of [
      'subject_has_user_access',
      'subject_user_has_role',
      'subject_can_create_crew',
      'subject_can_manage_runners',
      'subject_can_authorize_device_grant',
      'is_temporary_group_human_member',
      'can_view_temporary_group',
    ]) {
      expect(sql).toMatch(new RegExp(`function\\s+pendingbot\\.${name}\\s*\\(`, 'i'));
    }
    expect(sql.match(/auth\.uid\(\)\s+IS\s+NULL\s+OR\s+p_user_id\s*=\s*auth\.uid\(\)/gi)?.length)
      .toBeGreaterThanOrEqual(7);
  });

  it('pins search_path on legacy helper and trigger functions flagged by Supabase advisors', () => {
    const sql = readMigration('supabase/migrations/20260524181807_pin_legacy_function_search_path.sql');

    for (const name of [
      'gen_preset_handle_value',
      'uuidv7',
      'bootstrap_new_user_trigger',
      'check_handle_limit',
      'random_place_name',
      'bots_guard_public_update',
      'guard_preset_handle',
      '_group_member_billing_freeze_trigger',
    ]) {
      expect(sql).toMatch(new RegExp(`alter\\s+function\\s+pendingbot\\.${name}\\s*\\(\\)\\s+set\\s+search_path`, 'i'));
    }
  });

  it('opens user_user conversations atomically under auth.uid and a pair advisory lock', () => {
    const sql = readMigration('supabase/migrations/20260525093000_open_user_user_conversation_rpc.sql');

    expect(sql).toMatch(/function\s+pendingbot\.open_user_user_conv\s*\(\s*p_other_user_id\s+uuid\s*\)/i);
    expect(sql).toMatch(/v_user_id\s+uuid\s*:=\s*auth\.uid\(\)/i);
    expect(sql).toMatch(/pg_advisory_xact_lock/i);
    expect(sql).toMatch(/hashtextextended\(v_pair_a::text\s*\|\|\s*':'\s*\|\|\s*v_pair_b::text,\s*0\)/i);
    expect(sql).toMatch(/from\s+pendingbot\.user_contacts/i);
    expect(sql).toMatch(/grant\s+execute\s+on\s+function\s+pendingbot\.open_user_user_conv\(uuid\)\s+to\s+authenticated,\s*service_role/i);
  });

  it('keeps legacy runner execution RPCs off the authenticated PostgREST surface', () => {
    const sql = readMigration('supabase/migrations/20260525170500_revoke_legacy_runner_user_rpcs.sql');

    expect(sql).toMatch(/revoke\s+execute\s+on\s+function\s+pendingbot\.register_runner_host\(uuid,\s*text,\s*jsonb,\s*jsonb\)\s+from\s+authenticated,\s*anon,\s*public/i);
    expect(sql).toMatch(/revoke\s+execute\s+on\s+function\s+pendingbot\.runner_host_heartbeat\(uuid,\s*jsonb,\s*jsonb\)\s+from\s+authenticated,\s*anon,\s*public/i);
    expect(sql).toMatch(/revoke\s+execute\s+on\s+function\s+pendingbot\.claim_next_crew_session\(uuid,\s*jsonb\)\s+from\s+authenticated,\s*anon,\s*public/i);
    expect(sql).toMatch(/revoke\s+execute\s+on\s+function\s+pendingbot\.append_crew_session_event_from_runner\(\s*uuid,\s*uuid,\s*text,\s*text,\s*text,\s*jsonb,\s*text\s*\)\s+from\s+authenticated,\s*anon,\s*public/i);
    expect(sql).toMatch(/revoke\s+execute\s+on\s+function\s+pendingbot\.finish_crew_session_from_runner\(\s*uuid,\s*uuid,\s*text,\s*text,\s*jsonb,\s*text\s*\)\s+from\s+authenticated,\s*anon,\s*public/i);
  });
});
