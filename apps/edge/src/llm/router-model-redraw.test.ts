// 池子机器人抽到"根本调不通的模型"时，应该静默重抽，而不是把 404 甩给用户。
//
// 背景（线上实测，2026-08-25 Todo #15）：Rosales 是池子机器人，新会话开局
// 从池子里抽一个模型定死。抽中的模型如果在 OpenRouter 账号的数据政策下没有
// 任何可用线路，OpenRouter 返回 404 → classifyError 判 fatal → withFallback
// 第一跳就 break（这个路由是纯直通，一个模型只对应一个 provider，永远解析
// 不出第二家）→ 用户看到一句技术报错，而且他刚打的那句话被 /start 的回滚
// 连同会话一起删掉了。再发一次就好了，因为那是一次全新的抽签。
//
// 这里钉住的是：那次重抽应该由我们做，不该让用户做。
//
// 安全边界：只有 withFallback 的 runner 里能换模型 —— 它只负责"把流打开"，
// 抛错时一个字节都还没到客户端。开始出字之后换模型是不允许的。

import { describe, expect, it, vi } from 'vitest';
import {
  installFakeSupabaseMock,
  makeFakeDb,
  makeFakeEnv,
} from '../../tests/_helpers/fake-supabase';

vi.mock('../lib/llm-trace', () => ({
  traceGeneration: async () => {},
}));

installFakeSupabaseMock();

import {
  FallbackError,
  REDRAWABLE_ERROR_CLASSES,
  withFallback,
  type FallbackOpts,
  type ResolvedRoute,
} from './router';

function env() {
  const e = makeFakeEnv(makeFakeDb()) as unknown as Record<string, unknown>;
  e.CF_ACCOUNT_ID = 'acct-1';
  e.CF_AIG_GATEWAY = 'gw-1';
  e.CF_AIG_RUN_TOKEN = 'run-token';
  return e as never;
}

const supa = null as never;

/// OpenRouter's real reply when the account's data policy leaves no
/// endpoint for a model: a 404, which classifyError maps to 'not_found'.
function dataPolicy404() {
  return Object.assign(
    new Error(
      'No endpoints available matching your guardrail restrictions and data policy.',
    ),
    { status: 404 },
  );
}

/// A runner that rejects the named slugs with the data-policy 404 and
/// succeeds on anything else, recording what it was asked for.
function runnerRejecting(deadSlugs: string[]) {
  const asked: string[] = [];
  const run = async (r: ResolvedRoute) => {
    asked.push(r.modelToCall);
    if (deadSlugs.includes(r.modelToCall)) throw dataPolicy404();
    return { ok: r.modelToCall };
  };
  return { asked, run };
}

/// A pool that hands out its members in order, never repeating — the
/// contract `redrawUnusableConversationModel` implements with
/// strictExclude, reduced to what the router can observe.
function poolRedraw(order: string[]): FallbackOpts['redrawModel'] {
  let i = 0;
  return async () => {
    const next = order[i++];
    return next ? { modelSlug: next, preferProvider: 'openrouter' } : null;
  };
}

describe('REDRAWABLE_ERROR_CLASSES', () => {
  it('covers exactly the "this model is unreachable here" classes', () => {
    expect([...REDRAWABLE_ERROR_CLASSES].sort()).toEqual(['no_route', 'not_found']);
    // A bad request or an over-long context would fail on any model —
    // re-drawing would just burn the pool.
    expect(REDRAWABLE_ERROR_CLASSES.has('bad_request')).toBe(false);
    expect(REDRAWABLE_ERROR_CLASSES.has('context_length')).toBe(false);
    // Transient ones already have their own retry path.
    expect(REDRAWABLE_ERROR_CLASSES.has('rate_limit')).toBe(false);
  });
});

describe('withFallback — re-drawing an unreachable pool model', () => {
  it('swaps to another pool model and succeeds, invisibly', async () => {
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    const { asked, run } = runnerRejecting(['tencent/hy-mt2-1.8b']);

    const out = await withFallback(
      supa,
      env(),
      {
        modelSlug: 'tencent/hy-mt2-1.8b',
        preferProvider: 'openrouter',
        redrawModel: poolRedraw(['moonshotai/kimi-k3']),
      },
      run,
    );

    expect(asked).toEqual(['tencent/hy-mt2-1.8b', 'moonshotai/kimi-k3']);
    expect(out.result).toEqual({ ok: 'moonshotai/kimi-k3' });
    // The caller reads the model that actually ran off the route — audit,
    // billing and the conversation pin all depend on this being the
    // replacement, not the slug we started with.
    expect(out.route.modelToCall).toBe('moonshotai/kimi-k3');
  });

  it('keeps drawing while the pool keeps handing out dead models', async () => {
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    const { asked, run } = runnerRejecting(['dead-1', 'dead-2']);

    const out = await withFallback(
      supa,
      env(),
      {
        modelSlug: 'dead-1',
        preferProvider: 'openrouter',
        maxAttempts: 5,
        redrawModel: poolRedraw(['dead-2', 'alive']),
      },
      run,
    );

    expect(asked).toEqual(['dead-1', 'dead-2', 'alive']);
    expect(out.route.modelToCall).toBe('alive');
  });

  it('gives up with the original failure once the pool is exhausted', async () => {
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
    const { asked, run } = runnerRejecting(['dead-1', 'dead-2']);

    await expect(
      withFallback(
        supa,
        env(),
        {
          modelSlug: 'dead-1',
          preferProvider: 'openrouter',
          redrawModel: poolRedraw(['dead-2']), // then null — nothing left
        },
        run,
      ),
    ).rejects.toBeInstanceOf(FallbackError);

    expect(asked).toEqual(['dead-1', 'dead-2']);
  });

  it('does not re-draw for failures that are not about the model', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {});
    let redrawCalls = 0;
    const run = async () => {
      throw Object.assign(new Error('context length exceeded'), { status: 400 });
    };

    await expect(
      withFallback(
        supa,
        env(),
        {
          modelSlug: 'some/model',
          preferProvider: 'openrouter',
          redrawModel: async () => {
            redrawCalls += 1;
            return { modelSlug: 'other/model', preferProvider: 'openrouter' };
          },
        },
        run,
      ),
    ).rejects.toBeInstanceOf(FallbackError);

    expect(redrawCalls).toBe(0);
  });

  it('single-model bots (no hook) behave exactly as before', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {});
    const { asked, run } = runnerRejecting(['claude-opus-5']);

    const err = await withFallback(
      supa,
      env(),
      { modelSlug: 'claude-opus-5', preferProvider: 'anthropic' },
      run,
    ).catch((e) => e as FallbackError);

    expect(err).toBeInstanceOf(FallbackError);
    expect(asked).toEqual(['claude-opus-5']);
    // Still the one-attempt trace the old code produced.
    expect((err as FallbackError).routeTrace).toHaveLength(1);
  });

  it('a throwing re-draw hook degrades to the old behaviour, not a crash', async () => {
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    vi.spyOn(console, 'error').mockImplementation(() => {});
    const { run } = runnerRejecting(['dead-1']);

    await expect(
      withFallback(
        supa,
        env(),
        {
          modelSlug: 'dead-1',
          preferProvider: 'openrouter',
          redrawModel: async () => {
            throw new Error('KV down');
          },
        },
        run,
      ),
    ).rejects.toBeInstanceOf(FallbackError);
  });
});
