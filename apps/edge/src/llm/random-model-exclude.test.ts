// pickRandomModel 的排除语义有两个调用方，要的东西正好相反 —— 这里把两条
// 都钉住，因为默认那条的"排干净就退回原池"是个很容易踩的静默陷阱。
//
//   重新生成（默认，strictExclude 关）：排除只是「换一个」的偏好。一个模型
//     的池子不该被它卡死，所以排干净时回落到原池，可能再给同一个。
//
//   抽到不可用模型后重抽（strictExclude 开）：被排除的是刚刚**证实**打不通
//     的模型。这时回落到原池 = 把死模型又发一遍，拿它写重抽循环会原地打转
//     （Todo #15）。必须返回 null 让调用方停手。

import { describe, expect, it } from 'vitest';
import {
  installFakeSupabaseMock,
  makeFakeDb,
  makeFakeEnv,
  type FakeKv,
} from '../../tests/_helpers/fake-supabase';

installFakeSupabaseMock();

import { pickRandomModel } from './random-model';

const POOL_CACHE_KEY = 'model_pool:v2';

function envWithPool(slugs: string[]) {
  const kv: FakeKv = {
    store: {
      [POOL_CACHE_KEY]: slugs.map((slug) => ({
        slug,
        vendor: slug.split('/')[0] ?? slug,
        price: 1,
        releaseDate: '2026-01-01',
        modelProvider: null,
      })),
    },
    throws: false,
  };
  return makeFakeEnv(makeFakeDb(), { kv }) as never;
}

/// Explicit-models config with no price bounds — filterPool then yields
/// exactly these slugs, so the only thing under test is the exclusion.
function cfgFor(slugs: string[]) {
  return {
    price_min: null,
    price_max: null,
    models: slugs,
    exclude: null,
    vendors: null,
    release_window_days: null,
    presets: null,
  };
}

describe('pickRandomModel — exclusion semantics', () => {
  it('strict: returns null rather than handing back a model we proved dead', async () => {
    const picked = await pickRandomModel(
      envWithPool(['dead/only-model']),
      cfgFor(['dead/only-model']),
      { excludeSlugs: ['dead/only-model'], strictExclude: true },
    );
    expect(picked).toBeNull();
  });

  it('non-strict (regenerate): falls back rather than dead-ending a 1-model pool', async () => {
    const picked = await pickRandomModel(
      envWithPool(['solo/model']),
      cfgFor(['solo/model']),
      { excludeSlugs: ['solo/model'] },
    );
    expect(picked?.slug).toBe('solo/model');
  });

  it('strict: still draws while anything is left', async () => {
    const picked = await pickRandomModel(
      envWithPool(['dead/a', 'dead/b', 'alive/c']),
      cfgFor(['dead/a', 'dead/b', 'alive/c']),
      { excludeSlugs: ['dead/a', 'dead/b'], strictExclude: true },
    );
    expect(picked?.slug).toBe('alive/c');
  });

  it('strict: a repeated re-draw walks the pool down to empty and stops', async () => {
    const env = envWithPool(['m/1', 'm/2', 'm/3']);
    const cfg = cfgFor(['m/1', 'm/2', 'm/3']);
    const dead: string[] = [];
    // Simulate "every model in the pool is unreachable" — the loop must
    // terminate, not cycle.
    for (let i = 0; i < 10; i++) {
      const picked = await pickRandomModel(env, cfg, {
        excludeSlugs: dead,
        strictExclude: true,
      });
      if (!picked) break;
      expect(dead).not.toContain(picked.slug);
      dead.push(picked.slug);
    }
    expect(dead.sort()).toEqual(['m/1', 'm/2', 'm/3']);
  });

  it('no exclusion list at all behaves the same in both modes', async () => {
    const a = await pickRandomModel(envWithPool(['x/1']), cfgFor(['x/1']), {});
    const b = await pickRandomModel(envWithPool(['x/1']), cfgFor(['x/1']), {
      strictExclude: true,
    });
    expect(a?.slug).toBe('x/1');
    expect(b?.slug).toBe('x/1');
  });

});
