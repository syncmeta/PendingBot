import { describe, expect, it, vi } from 'vitest';
import type { Memory } from '../lib/memory';
import type { Env } from '../types';
import { buildMessages } from './builder';

vi.mock('../i18n/prompts', () => ({
  loadPrompt: vi.fn(async (_env: unknown, name: string) => `prompt:${name}`),
}));

const env = {} as Env;
const botMemory: Memory = {
  card: [],
  representation: 'I am a bot.',
  syncedAt: '2026-05-12T00:00:00.000Z',
  lastCoveredMessageId: null,
};

// The system message content is wrapped in the cache-control block array;
// pull the raw text out for substring assertions.
function systemText(content: unknown): string {
  if (Array.isArray(content)) {
    return content.map((p) => (p as { text?: string }).text ?? '').join('');
  }
  return String(content);
}

describe('buildMessages identity section', () => {
  it('injects the bot display name as a system section', async () => {
    const messages = await buildMessages(env, {
      bot: { id: 'bot-1', output_mode: 'single', display_name: '小绿' },
      botMemory,
      skills: [],
      botNote: null,
      chatMemo: null,
      recentContext: [],
      newMessage: '你叫什么名字',
    });

    const sys = systemText(messages[0]?.content);
    expect(sys).toContain('你的名字');
    expect(sys).toContain('小绿');
  });

  it('omits the identity section when the bot has no name', async () => {
    const messages = await buildMessages(env, {
      bot: { id: 'bot-1', output_mode: 'single' },
      botMemory,
      skills: [],
      botNote: null,
      chatMemo: null,
      recentContext: [],
      newMessage: 'hi',
    });

    expect(systemText(messages[0]?.content)).not.toContain('你的名字');
  });
});

describe('buildMessages bot self-tz', () => {
  it('renders the "你所在的时区" system block when the bot has a tz', async () => {
    const messages = await buildMessages(env, {
      bot: { id: 'bot-1', output_mode: 'single', tz: 'Asia/Shanghai' },
      botMemory,
      skills: [],
      botNote: null,
      chatMemo: null,
      recentContext: [],
      newMessage: 'hi',
    });

    const sys = systemText(messages[0]?.content);
    expect(sys).toContain('你所在的时区');
    expect(sys).toContain('Asia/Shanghai');
  });

  it('falls back to the bot tz for the time hint when clientTz is absent (group dispatch)', async () => {
    // Group dispatch never has clientTz on the request — the bot's own
    // tz drives the per-message timestamp instead of dropping to UTC.
    const messages = await buildMessages(env, {
      bot: { id: 'bot-1', output_mode: 'single', tz: 'Asia/Shanghai' },
      botMemory,
      skills: [],
      botNote: null,
      chatMemo: null,
      recentContext: [],
      newMessage: '现在几点',
      nowIso: '2026-05-12T03:23:45.000Z',
    });

    expect(messages.at(-1)?.content).toContain('2026年5月12日 11:23:45');
  });

  it('uses clientTz over bot.tz when both are present (1:1 chat)', async () => {
    const messages = await buildMessages(env, {
      bot: { id: 'bot-1', output_mode: 'single', tz: 'Etc/UTC' },
      botMemory,
      skills: [],
      botNote: null,
      chatMemo: null,
      recentContext: [],
      newMessage: '现在几点',
      clientTz: 'Asia/Shanghai',
      nowIso: '2026-05-12T03:23:45.000Z',
    });

    // listener wins — 11:23 in Shanghai, not 03:23 UTC
    expect(messages.at(-1)?.content).toContain('2026年5月12日 11:23:45');
  });
});

describe('buildMessages cache prefix', () => {
  // The whole point of the cache restructure: the system message holds only
  // the stable persona (cacheable) and carries the cache_control breakpoint;
  // per-turn volatile context (lookbacks, attachment inventory) must NOT be
  // in it, or it busts the cached prefix every round.
  it('marks the system message with a cache_control breakpoint', async () => {
    const messages = await buildMessages(env, {
      bot: { id: 'bot-1', output_mode: 'single' },
      botMemory,
      skills: [],
      botNote: null,
      chatMemo: null,
      recentContext: [],
      newMessage: 'hi',
    });

    const content = messages[0]?.content as unknown as Array<{
      type: string;
      cache_control?: { type: string };
    }>;
    expect(Array.isArray(content)).toBe(true);
    expect(content[content.length - 1]?.cache_control).toEqual({ type: 'ephemeral' });
  });

  it('keeps lookbacks out of the system prefix and on the current turn', async () => {
    const messages = await buildMessages(env, {
      bot: { id: 'bot-1', output_mode: 'single' },
      botMemory,
      skills: [],
      botNote: null,
      chatMemo: null,
      lookbacks: [{ id: 'lb-1', body_md: '上次说的是周三不是周四' }],
      recentContext: [],
      newMessage: '继续',
    });

    // Not in the cached system prefix...
    expect(systemText(messages[0]?.content)).not.toContain('周三不是周四');
    // ...but present on the current (uncached) user turn.
    const last = messages.at(-1)?.content as Array<{ type: string; text?: string }>;
    expect(Array.isArray(last)).toBe(true);
    const joined = last.map((p) => p.text ?? '').join('\n');
    expect(joined).toContain('周三不是周四');
    expect(joined).toContain('继续');
  });

  it('keeps the attachment inventory out of the system prefix', async () => {
    const messages = await buildMessages(env, {
      bot: { id: 'bot-1', output_mode: 'single' },
      botMemory,
      skills: [],
      botNote: null,
      chatMemo: null,
      attachmentInventory: [
        {
          id: 'aabbccdd-1111-2222-3333-444455556666',
          summary: '一只橘猫',
          tags: ['cat'],
          status: 'done',
        },
      ],
      recentContext: [],
      newMessage: '看这个',
    });

    expect(systemText(messages[0]?.content)).not.toContain('一只橘猫');
    const last = messages.at(-1)?.content as Array<{ type: string; text?: string }>;
    expect(last.map((p) => p.text ?? '').join('\n')).toContain('一只橘猫');
  });
});

describe('buildMessages time hints', () => {
  it('includes the full year for the current user turn in the client timezone', async () => {
    const messages = await buildMessages(env, {
      bot: { id: 'bot-1', output_mode: 'single' },
      botMemory,
      skills: [],
      botNote: null,
      chatMemo: null,
      recentContext: [],
      newMessage: '现在是哪一年',
      clientTz: 'Asia/Shanghai',
      nowIso: '2026-05-12T03:23:45.000Z',
    });

    expect(messages.at(-1)?.content).toContain('2026年5月12日 11:23:45');
  });

  it('includes the full year for historical user turns with explicit offsets', async () => {
    const messages = await buildMessages(env, {
      bot: { id: 'bot-1', output_mode: 'single' },
      botMemory,
      skills: [],
      botNote: null,
      chatMemo: null,
      recentContext: [
        {
          role: 'user',
          content: '昨天聊到这里',
          created_at: '2026-05-08T11:23:45+08:00',
        },
      ],
      newMessage: '继续',
      clientTz: 'America/Los_Angeles',
      nowIso: '2026-05-12T03:23:45.000Z',
    });

    expect(messages[1]?.content).toContain('2026年5月8日 11:23:45');
  });
});
