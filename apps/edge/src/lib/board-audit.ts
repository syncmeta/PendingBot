// apps/edge/src/lib/board-audit.ts
//
// Board 管理台的两块公共件:
//   1. isBoardAdmin —— requireAdmin 的 lookup:查 pendingbot.users.is_admin。
//   2. recordBoardAudit —— 每次 board 写操作落一条 admin_audit(before/after)。
//
// admin_audit 表列(已存在,见 schema.ts):
//   action / actor_id / target_kind / target_id / before / after /
//   ip / user_agent / created_at / id
import type { Context } from 'hono';
import { serviceClient } from './supabase';
import type { AppBindings } from '../types';

// requireAdmin 的 isAdminLookup:当前会话用户是否 is_admin。
export async function isBoardAdmin(c: Context<AppBindings>): Promise<boolean> {
  const userId = c.var.userId;
  if (!userId) return false;
  const svc = serviceClient(c.env);
  const { data, error } = await svc
    .schema('pendingbot')
    .from('users')
    .select('is_admin')
    .eq('id', userId)
    .maybeSingle();
  if (error || !data) return false;
  return data.is_admin === true;
}

export interface BoardAuditInput {
  action: 'create' | 'update' | 'delete';
  targetKind: string;
  targetId: string | null;
  before: unknown;
  after: unknown;
}

// 落一条审计。失败不抛 —— 审计写失败不应让已成功的业务写回滚成错误,
// 但要 console.error 让其在 tail 里可见(审计漏写是要追的)。
export async function recordBoardAudit(
  c: Context<AppBindings>,
  input: BoardAuditInput,
): Promise<void> {
  try {
    const svc = serviceClient(c.env);
    await svc.schema('pendingbot').from('admin_audit').insert({
      actor_id: c.var.userId ?? null,
      action: input.action,
      target_kind: input.targetKind,
      target_id: input.targetId,
      before: (input.before ?? null) as never,
      after: (input.after ?? null) as never,
      ip: c.req.header('cf-connecting-ip') ?? null,
      user_agent: c.req.header('user-agent') ?? null,
    });
  } catch (err) {
    console.error('[board] audit insert failed', err);
  }
}
