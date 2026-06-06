import { describe, it, expect, vi, beforeEach } from 'vitest';

const { putMock } = vi.hoisted(() => ({ putMock: vi.fn() }));
vi.mock('../llm/prompt-loader', () => ({ putPromptRecord: putMock }));

import { langfusePromptRoutes } from './langfuse-prompts';

const SECRET = 'whsec_test';
const enc = new TextEncoder();

async function sign(body: string, secret = SECRET, t = '1700000000'): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw',
    enc.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const mac = await crypto.subtle.sign('HMAC', key, enc.encode(`${t}.${body}`));
  const hex = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, '0')).join('');
  return `t=${t},s=${hex}`;
}

function post(body: string, sig: string | null, secret: string | undefined = SECRET) {
  const headers: Record<string, string> = { 'content-type': 'application/json' };
  if (sig) headers['x-langfuse-signature'] = sig;
  return langfusePromptRoutes.request(
    '/prompt-webhook',
    { method: 'POST', headers, body },
    { LANGFUSE_WEBHOOK_SECRET: secret },
  );
}

const prodPayload = JSON.stringify({
  prompt: { name: 'system/zh', version: 7, labels: ['production'], type: 'text', prompt: 'hello' },
});

beforeEach(() => putMock.mockReset());

describe('langfuse prompt webhook', () => {
  it('501 when no secret configured', async () => {
    const res = await langfusePromptRoutes.request(
      '/prompt-webhook',
      { method: 'POST', headers: { 'content-type': 'application/json' }, body: prodPayload },
      {}, // env without LANGFUSE_WEBHOOK_SECRET
    );
    expect(res.status).toBe(501);
  });

  it('401 on missing or invalid signature', async () => {
    expect((await post(prodPayload, null)).status).toBe(401);
    expect((await post(prodPayload, 't=1,s=deadbeef')).status).toBe(401);
    expect(putMock).not.toHaveBeenCalled();
  });

  it('applies a production text prompt to KV on a valid signature', async () => {
    const res = await post(prodPayload, await sign(prodPayload));
    expect(res.status).toBe(200);
    expect(putMock).toHaveBeenCalledWith(expect.anything(), 'system', 'zh', {
      body: 'hello',
      version: 7,
    });
  });

  it('ignores events without the production label', async () => {
    const draft = JSON.stringify({
      prompt: { name: 'system/zh', version: 8, labels: ['latest'], type: 'text', prompt: 'x' },
    });
    const res = await post(draft, await sign(draft));
    expect(res.status).toBe(200);
    expect(putMock).not.toHaveBeenCalled();
  });

  it('ignores unknown prompt names', async () => {
    const unknown = JSON.stringify({
      prompt: { name: 'totally-unknown/zh', version: 1, labels: ['production'], type: 'text', prompt: 'x' },
    });
    const res = await post(unknown, await sign(unknown));
    expect(res.status).toBe(200);
    expect(putMock).not.toHaveBeenCalled();
  });
});
