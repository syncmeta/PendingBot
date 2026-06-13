// apps/edge/src/lib/board-audit.ts
//
// recordBoardAudit —— 每次 board 写操作落一条 admin_audit(before/after)。
// 身份/授权由 cf-access.ts 的 requireCfAccess + requireBoardAdmin 负责(Cloudflare
// Access 是唯一身份源);这里只把已验证的 actor 邮箱记进审计。
//
// admin_audit 表列(见 schema.ts):
//   action / actor_id(legacy uuid)/ actor_email / target_kind / target_id /
//   before / after / ip / user_agent / created_at / id
import type { Context } from 'hono';
import { serviceClient } from './supabase';
import type { AppBindings } from '../types';

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
      // Identity comes from Cloudflare Access now, not a Supabase user — record
      // the verified email; actor_id (uuid FK) stays null for board writes.
      actor_id: null,
      actor_email: c.var.boardEmail ?? null,
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
