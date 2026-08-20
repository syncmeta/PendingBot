import { describe, expect, it } from 'vitest';
import { makeFakeClient, makeFakeDb } from '../../tests/_helpers/fake-supabase';
import {
  WalletSubjectUnresolvedError,
  findUserWalletSubjectId,
  resolveSubjectUserId,
  resolveUserWalletSubjectId,
  resolveWalletSubjectKey,
} from './subject-key';

/// 每个用例用独立 id —— 解析器带进程内缓存(映射由 subject_foundation 建后不变),
/// 复用 id 会串味。
function dbWith(rows: Array<Record<string, unknown>>) {
  return makeFakeClient(makeFakeDb({ subjects: rows }));
}

describe('resolveUserWalletSubjectId', () => {
  it('auth user id → 其 user_account subject id(不是 user id 本身)', async () => {
    const supa = dbWith([
      { id: 'sub-a', user_id: 'user-a', kind: 'user_account' },
    ]);
    expect(await resolveUserWalletSubjectId(supa, 'user-a')).toBe('sub-a');
  });

  it('只认 kind=user_account —— 同一用户的群主体不当个人钱包', async () => {
    const supa = dbWith([
      { id: 'grp-b', user_id: 'user-b', kind: 'group_account' },
      { id: 'sub-b', user_id: 'user-b', kind: 'user_account' },
    ]);
    expect(await resolveUserWalletSubjectId(supa, 'user-b')).toBe('sub-b');
  });

  it('解析不到 → 抛 WalletSubjectUnresolvedError(绝不静默回退成 user id)', async () => {
    const supa = dbWith([]);
    await expect(resolveUserWalletSubjectId(supa, 'user-c')).rejects.toBeInstanceOf(
      WalletSubjectUnresolvedError,
    );
  });

  it('查询报错 → 抛 WalletSubjectUnresolvedError(不吞成 0 余额)', async () => {
    const db = makeFakeDb({ subjects: [{ id: 'sub-d', user_id: 'user-d', kind: 'user_account' }] });
    db.errors = { select: () => ({ message: 'db down' }) };
    await expect(
      resolveUserWalletSubjectId(makeFakeClient(db), 'user-d'),
    ).rejects.toBeInstanceOf(WalletSubjectUnresolvedError);
  });

  it('命中后缓存,不再打 DB', async () => {
    const db = makeFakeDb({ subjects: [{ id: 'sub-e', user_id: 'user-e', kind: 'user_account' }] });
    const supa = makeFakeClient(db);
    expect(await resolveUserWalletSubjectId(supa, 'user-e')).toBe('sub-e');
    db.rows.subjects = []; // 行没了,缓存还在
    expect(await resolveUserWalletSubjectId(supa, 'user-e')).toBe('sub-e');
  });

  it('未命中不进缓存(主体可能稍后由触发器建出来)', async () => {
    const db = makeFakeDb({ subjects: [] });
    const supa = makeFakeClient(db);
    await expect(resolveUserWalletSubjectId(supa, 'user-f')).rejects.toBeInstanceOf(
      WalletSubjectUnresolvedError,
    );
    db.rows.subjects = [{ id: 'sub-f', user_id: 'user-f', kind: 'user_account' }];
    expect(await resolveUserWalletSubjectId(supa, 'user-f')).toBe('sub-f');
  });
});

describe('findUserWalletSubjectId', () => {
  it('解析不到 → null(调用方自己 fail-open + 记日志)', async () => {
    expect(await findUserWalletSubjectId(dbWith([]), 'user-g')).toBeNull();
  });

  it('解析得到 → subject id', async () => {
    const supa = dbWith([{ id: 'sub-h', user_id: 'user-h', kind: 'user_account' }]);
    expect(await findUserWalletSubjectId(supa, 'user-h')).toBe('sub-h');
  });
});

describe('resolveWalletSubjectKey', () => {
  it('kind=user → 解析成 subject id', async () => {
    const supa = dbWith([{ id: 'sub-i', user_id: 'user-i', kind: 'user_account' }]);
    expect(await resolveWalletSubjectKey(supa, { kind: 'user', userId: 'user-i' })).toBe('sub-i');
  });

  it('kind=subject → 原样(群责任主体本来就是 subjects.id)', async () => {
    expect(
      await resolveWalletSubjectKey(dbWith([]), { kind: 'subject', subjectId: 'grp-j' }),
    ).toBe('grp-j');
  });
});

describe('resolveSubjectUserId (反向:群注资/认缴表按 user id 存)', () => {
  it('subject id → subjects.user_id', async () => {
    const supa = dbWith([{ id: 'sub-k', user_id: 'user-k', kind: 'user_account' }]);
    expect(await resolveSubjectUserId(supa, 'sub-k')).toBe('user-k');
  });

  it('查无此主体 → null', async () => {
    expect(await resolveSubjectUserId(dbWith([]), 'sub-l')).toBeNull();
  });
});
