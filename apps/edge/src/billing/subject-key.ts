// 个人钱包主体键的**唯一**解析器 —— auth user id ⇄ subjects.id(kind='user_account')。
//
// 为什么必须只有这一处:入账侧被外键钉死在 subjects.id
// (`pnc_ledger.subject_id → subjects(id)`,`welcome_bonus_grants.subject_id` 同),
// 所以充值/赠送/退款只可能记在 subject id 上,Polar customer 的 external_id 也是它。
// 而门禁/扣费侧拿到的是 JWT 里的 auth user id(`packages/identity` 的 `c.var.userId`)。
// 两侧一旦用不同的键,`WalletDO`(`idFromName(key)`)就落到两个不同的 DO:钱进了 A,
// 闸读的是 B,于是"充多少都提示余额耗尽"。这正是 2026-08-18 那次事故的形态。
//
// 纪律:任何要碰个人钱包(WalletDO / Polar / pnc_ledger)的地方,都必须先过本模块,
// **不许**把 user id 当 subject 用、也不许在解析失败时静默回退成 user id ——
// 静默回退就是把事故重新种回去。解析失败要么抛(fail-loud),要么由调用方显式
// fail-open 并留日志。
//
// 群责任主体(responsible_subject_id / group_pools.subject_id)本来就是 subjects.id,
// 不经本模块转换;反过来 group_contributions.contributor_user_id / group_pledges.user_id
// 存的是 auth user id(外键指向 users),要拿它们碰个人钱包时同样得先解析。
import type { SupabaseClient } from '../lib/supabase';
import type { WalletOwner } from './wallet-client';

/** 解析所需的最小 supabase 面(便于单测注入,也兼容 group-wallet 的宽松 client 类型)。 */
export interface SubjectKeyLookup {
  from(table: string): {
    select(cols: string): {
      eq(col: string, v: string): {
        eq(col: string, v: string): {
          maybeSingle(): Promise<{
            data: { id?: string; user_id?: string | null } | null;
            error?: { message?: string } | null;
          }>;
        };
        maybeSingle(): Promise<{
          data: { id?: string; user_id?: string | null } | null;
          error?: { message?: string } | null;
        }>;
      };
    };
  };
}

/** 传 service client / user client / 单测 fake 都行。 */
export type AnySupa = SupabaseClient | SubjectKeyLookup;

/** 解析不到个人钱包主体键。**不要**把它降级成"余额 0",那就是原事故。 */
export class WalletSubjectUnresolvedError extends Error {
  userId: string;
  constructor(userId: string, reason: string) {
    super(`no user_account subject for user ${userId} (${reason})`);
    this.name = 'WalletSubjectUnresolvedError';
    this.userId = userId;
  }
}

// user_account subject 由 subject_foundation 在建号时一次性建出,之后 id 不变,
// 所以命中可以放心缓存(isolate 生命周期);**未命中不缓存** —— 主体可能稍后才落库。
// 上限只是防 isolate 长命时无界增长,撑满直接清空(重建成本 = 一次索引查询)。
const MAX_CACHE = 5_000;
const userToSubject = new Map<string, string>();
const subjectToUser = new Map<string, string>();

function remember(cache: Map<string, string>, k: string, v: string): void {
  if (cache.size >= MAX_CACHE) cache.clear();
  cache.set(k, v);
}

/**
 * auth user id → 其 user_account subject id。解析不到/查询报错 → 抛
 * `WalletSubjectUnresolvedError`(fail-loud)。要 fail-open 的调用方用
 * `findUserWalletSubjectId`,并**自己写日志**。
 */
export async function resolveUserWalletSubjectId(
  supa: AnySupa,
  userId: string,
): Promise<string> {
  if (!userId) throw new WalletSubjectUnresolvedError(userId, 'empty user id');
  const cached = userToSubject.get(userId);
  if (cached) return cached;

  const { data, error } = await (supa as SubjectKeyLookup)
    .from('subjects')
    .select('id')
    .eq('user_id', userId)
    .eq('kind', 'user_account')
    .maybeSingle();
  if (error) {
    throw new WalletSubjectUnresolvedError(userId, `lookup failed: ${error.message ?? 'unknown'}`);
  }
  const id = data?.id;
  if (typeof id !== 'string' || id.length === 0) {
    throw new WalletSubjectUnresolvedError(userId, 'no row');
  }
  remember(userToSubject, userId, id);
  return id;
}

/** 同上,但解析不到返回 null。调用方**必须**显式处理 + 记日志。 */
export async function findUserWalletSubjectId(
  supa: AnySupa,
  userId: string,
): Promise<string | null> {
  try {
    return await resolveUserWalletSubjectId(supa, userId);
  } catch {
    return null;
  }
}

/** 责任主体 → WalletDO 路由键:群主体原样,个人经解析器。 */
export async function resolveWalletSubjectKey(
  supa: AnySupa,
  owner: WalletOwner,
): Promise<string> {
  return owner.kind === 'subject'
    ? owner.subjectId
    : resolveUserWalletSubjectId(supa, owner.userId);
}

/**
 * 反向:subject id → 该主体的 auth user id。群注资/认缴表按 user id 存,
 * 而 webhook 侧手上只有 subject id,需要这一跳。查不到返回 null。
 */
export async function resolveSubjectUserId(
  supa: AnySupa,
  subjectId: string,
): Promise<string | null> {
  if (!subjectId) return null;
  const cached = subjectToUser.get(subjectId);
  if (cached) return cached;

  const { data, error } = await (supa as SubjectKeyLookup)
    .from('subjects')
    .select('user_id')
    .eq('id', subjectId)
    .eq('kind', 'user_account')
    .maybeSingle();
  if (error) return null;
  const uid = data?.user_id;
  if (typeof uid !== 'string' || uid.length === 0) return null;
  remember(subjectToUser, subjectId, uid);
  return uid;
}
