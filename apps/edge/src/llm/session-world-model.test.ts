// Smoke tests for renderSessionWorldModel — pins the template-variable
// substitution contract. Each test seeds a minimal DB, calls the helper,
// and asserts the {{var}} slots are filled (no literal `{{name}}` leaks)
// + the spec-v2 §9.5 sections all appear in the rendered output.

import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  installFakeSupabaseMock,
  makeFakeDb,
  makeFakeEnv,
  type FakeDb,
} from '../../tests/_helpers/fake-supabase';

installFakeSupabaseMock();

// prompt-loader.ts imports .md files via the wrangler Text rule, which
// vitest's rollup transformer can't parse. Stub it with a minimal
// template that exercises the same {{var}} substitution path so the
// helper's contract stays testable. Keep the two locales' templates
// distinguishable so the locale test can assert routing.
vi.mock('./prompt-loader', () => {
  const ZH = `# 你的世界
## 1. 你是谁 — task: {{sessionTaskBrief}} runner: {{runnerKind}} ({{sessionId}})
## 2. 你的 IO 去哪了
## 3. 群聊是什么
## 4. 谁是人类
{{humanRoster}}
## 5. 谁是 captain
{{captainBlock}}
## 6. 父 / 子 crew
{{lineageBlock}}
## 7. 拍板方
{{sharesBlock}}
冲突时听 {{tiebreakerBlock}}
## 8. 你怎么发消息 — post_to_crew
带 mentions 定向 @ 某个 session / @captain;reply_to 回复某条会自动 @ 原发送者。
## 9. 你怎么读群聊白板
每条消息前缀是发送者的显示名,据此判断是谁说的、该回应谁。
## 10. Permission Request 模式: {{permissionMode}}
crew: {{crewTitle}} ({{crewId}}) at {{runtimeLocation}}:{{workingDirectory}}
`;
  const EN = `# Your World
## 1. Who you are — task: {{sessionTaskBrief}} runner: {{runnerKind}} ({{sessionId}})
## 2. Where your IO goes
## 3. What the group chat is
## 4. Who the humans are
{{humanRoster}}
## 5. Who the captain is
Captain bot: {{captainBlock}}
## 6. Parent / child crews
{{lineageBlock}}
## 7. Tiebreaker
{{sharesBlock}}
On conflict, listen to {{tiebreakerBlock}}
## 8. How you send messages — post_to_crew
Attach mentions to @ a specific session / @captain; reply_to to a message auto-@'s the original sender.
## 9. How you read the whiteboard
Each message is prefixed with the sender's display name, so you know who said what and whom to respond to.
## 10. Permission Request mode: {{permissionMode}}
crew: {{crewTitle}} ({{crewId}}) at {{runtimeLocation}}:{{workingDirectory}}
`;
  return {
    ensurePromptOverridesLoaded: async () => undefined,
    getPrompt: (_name: string, locale: string = 'zh') => (locale === 'en' ? EN : ZH),
  };
});

// eslint-disable-next-line @typescript-eslint/no-explicit-any
let renderSessionWorldModel: (...args: any[]) => Promise<string | null>;

beforeEach(async () => {
  vi.resetModules();
  ({ renderSessionWorldModel } = await import('./session-world-model'));
});

const CREW_ID = '33333333-3333-4333-8333-cccccccccccc';
const SESSION_ID = '44444444-4444-4444-8444-dddddddddddd';
const USER_ID = 'user-1';
const CAPTAIN_BOT_ID = '66666666-6666-4666-8666-ffffffffffff';
const SUBJECT_ID = '11111111-1111-4111-8111-aaaaaaaaaaaa';
const PARENT_CREW_ID = '88888888-8888-4888-8888-000000000001';
const PARENT_SUBJECT_ID = '99999999-9999-4999-8999-000000000002';

function seedHappyPath(db: FakeDb) {
  db.rows.crew_sessions = [
    {
      id: SESSION_ID,
      crew_conversation_id: CREW_ID,
      runner_kind: 'local_claude_code',
      task_brief: '把首页的 banner 换成黑底白字',
      assigned_to_member_id: null,
      status: 'running',
      responsible_subject_id: SUBJECT_ID,
    },
  ];
  db.rows.temporary_group_meta = [
    {
      conversation_id: CREW_ID,
      title: '工程 Crew',
      captain_bot_id: CAPTAIN_BOT_ID,
      runtime_location: 'local_host',
      working_directory: '/Users/me/proj',
      responsible_subject_id: SUBJECT_ID,
      parent_temporary_group_id: PARENT_CREW_ID,
    },
    {
      conversation_id: PARENT_CREW_ID,
      title: '总指挥 Crew',
      responsible_subject_id: PARENT_SUBJECT_ID,
      captain_bot_id: null,
      runtime_location: 'local_host',
      working_directory: null,
    },
  ];
  db.rows.temporary_group_members = [
    {
      id: 'mem-1',
      conversation_id: CREW_ID,
      member_kind: 'human',
      user_id: USER_ID,
      display_name: 'Alice',
      role: 'owner',
      status: 'active',
    },
  ];
  db.rows.crew_parent_links = [
    {
      parent_crew_id: PARENT_CREW_ID,
      child_crew_id: CREW_ID,
      child_share_bps: 6000,
    },
  ];
  db.rows.crew_responsibility_shares = [
    {
      crew_conversation_id: CREW_ID,
      subject_id: SUBJECT_ID,
      share_bps: 6000,
      is_tiebreaker: false,
    },
    {
      crew_conversation_id: CREW_ID,
      subject_id: PARENT_SUBJECT_ID,
      share_bps: 4000,
      is_tiebreaker: true,
    },
  ];
  db.rows.subjects = [
    { id: SUBJECT_ID, display_name: 'Alice 个人账号' },
    { id: PARENT_SUBJECT_ID, display_name: '工程团队' },
  ];
  db.rows.bots = [{ id: CAPTAIN_BOT_ID, display_name: '机长小蓝' }];
}

describe('renderSessionWorldModel', () => {
  it('returns null for unknown session', async () => {
    const db = makeFakeDb();
    const env = makeFakeEnv(db);
    const out = await renderSessionWorldModel(env, SESSION_ID);
    expect(out).toBeNull();
  });

  it('renders all spec-v2 §9.5 sections + leaves no unfilled {{var}} slots', async () => {
    const db = makeFakeDb();
    seedHappyPath(db);
    const env = makeFakeEnv(db);
    const out = await renderSessionWorldModel(env, SESSION_ID);
    expect(out).toBeTruthy();
    if (!out) return;

    // All 10 §9.5 sections should be present in the rendered output.
    expect(out).toContain('## 1.');
    expect(out).toContain('## 2.');
    expect(out).toContain('## 3.');
    expect(out).toContain('## 4.');
    expect(out).toContain('## 5.');
    expect(out).toContain('## 6.');
    expect(out).toContain('## 7.');
    expect(out).toContain('## 8.');
    expect(out).toContain('## 9.');
    expect(out).toContain('## 10.');

    // No literal {{var}} leakage.
    expect(out).not.toMatch(/\{\{[a-zA-Z]+\}\}/);

    // Filled-in values surface.
    expect(out).toContain('把首页的 banner 换成黑底白字'); // task_brief
    expect(out).toContain('工程 Crew');                  // crew title
    expect(out).toContain('Alice');                      // human roster
    expect(out).toContain('机长小蓝');                    // captain name
    expect(out).toContain('Alice 个人账号');              // share subject
    expect(out).toContain('工程团队');                    // tiebreaker subject
    expect(out).toContain('60.00%');                     // share 6000 bps
    expect(out).toContain('40.00%');                     // share 4000 bps
    expect(out).toContain('local_host');                 // runtime location
    expect(out).toContain('/Users/me/proj');             // working dir
  });

  it('falls back to "(暂无)" for empty fields', async () => {
    const db = makeFakeDb();
    db.rows.crew_sessions = [
      {
        id: SESSION_ID,
        crew_conversation_id: CREW_ID,
        runner_kind: 'local_codex',
        task_brief: '',
        assigned_to_member_id: null,
        status: 'queued',
        responsible_subject_id: SUBJECT_ID,
      },
    ];
    db.rows.temporary_group_meta = [
      {
        conversation_id: CREW_ID,
        title: null,
        captain_bot_id: null,
        runtime_location: 'local_host',
        working_directory: null,
        responsible_subject_id: SUBJECT_ID,
      },
    ];
    db.rows.temporary_group_members = [];
    db.rows.crew_responsibility_shares = [];
    const env = makeFakeEnv(db);
    const out = await renderSessionWorldModel(env, SESSION_ID);
    expect(out).toBeTruthy();
    if (!out) return;
    expect(out).toContain('暂无指定 captain');       // no captain block fallback
    expect(out).toContain('没有父 / 子 crew');       // lineage empty fallback
    expect(out).toContain('暂无拍板方');             // tiebreaker empty fallback
    expect(out).not.toMatch(/\{\{[a-zA-Z]+\}\}/);    // no literal {{var}}
  });

  it('respects locale=en when requested', async () => {
    const db = makeFakeDb();
    seedHappyPath(db);
    const env = makeFakeEnv(db);
    const out = await renderSessionWorldModel(env, SESSION_ID, { locale: 'en' });
    expect(out).toBeTruthy();
    if (!out) return;
    expect(out).toContain('Your World');     // English title
    expect(out).toContain('Captain bot');    // English label
    expect(out).not.toMatch(/\{\{[a-zA-Z]+\}\}/);
  });

  // Phase 7 — the world-model must teach the new crew-comms abilities:
  // directed @ via mentions, reply_to (auto-@ original sender), and that the
  // whiteboard now shows sender display names. Assert in both locales.
  it('explains @ / reply / sender-identity (zh)', async () => {
    const db = makeFakeDb();
    seedHappyPath(db);
    const env = makeFakeEnv(db);
    const out = await renderSessionWorldModel(env, SESSION_ID);
    expect(out).toBeTruthy();
    if (!out) return;
    expect(out).toContain('mentions');        // directed @ ability
    expect(out).toContain('reply_to');        // reply-to-a-message ability
    expect(out).toContain('原发送者');         // auto-@ original sender
    expect(out).toContain('发送者的显示名');   // whiteboard shows sender name
  });

  it('explains @ / reply / sender-identity (en)', async () => {
    const db = makeFakeDb();
    seedHappyPath(db);
    const env = makeFakeEnv(db);
    const out = await renderSessionWorldModel(env, SESSION_ID, { locale: 'en' });
    expect(out).toBeTruthy();
    if (!out) return;
    expect(out).toContain('mentions');             // directed @ ability
    expect(out).toContain('reply_to');             // reply-to-a-message ability
    expect(out).toContain('original sender');      // auto-@ original sender
    expect(out).toContain("sender's display name"); // whiteboard shows sender name
  });
});
