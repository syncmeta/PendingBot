-- Seed the first-party `code-runner` preset skill. Subscribing to this
-- skill is the user-facing way to grant the bot the execute_code tool
-- (gated via frontmatter.allowed_tools per 0026).
--
-- First-party skills get migration-seeded rather than going through
-- scripts/seed-public-skills.mjs because:
--   1. Migrations are the single source of truth for required state
--      after a `supabase db push`.
--   2. The seed script needs the service-role key locally; not every
--      environment that runs migrations has that to hand.
--   3. The .md content under apps/edge/prompts/skills/pendingbot/ is the
--      readable copy for git diffs / PRs; this row is the runtime copy.
--      They drift only when someone forgets to add a follow-up
--      migration after editing the .md — call it out in PR review.
--
-- Idempotent: NOT EXISTS guard on (owner_id IS NULL AND
-- frontmatter->>'name' = 'code-runner').

BEGIN;

INSERT INTO pendingbot.skills (
  owner_id, bot_id, user_id, visibility, frontmatter, body_md
)
SELECT
  NULL, NULL, NULL, 'public',
  jsonb_build_object(
    'name', 'code-runner',
    'description', '给机器人开放在沙箱里跑 Python 代码的能力，用于做计算、解析数据、抓简单 API、画图、做小型实验。订阅这条技能就把 execute_code 工具注入到机器人能用的工具列表里。机器人会自己判断什么时候该跑代码、什么时候不该（聊天 / 解释 / 闲聊 都不该跑）。',
    'allowed_tools', jsonb_build_array('execute_code')
  ),
$body$# Code Runner

订阅了这条技能后，机器人会拿到一个叫 `execute_code` 的工具。它对应一个**只属于这个会话**的 Daytona 沙箱（per-conversation），cron 每小时清扫一次空闲的沙箱。

## 沙箱默认环境

- Python 3，标准 image
- 预装：`numpy`、`pandas`、`matplotlib`、`pillow`、`requests`、`httpx`、`python-dateutil`
- 30 秒单次执行硬上限
- stdout + stderr 合并返回，截断在 8 KiB
- 没有 stdin（不要用 `input()`）

## 什么时候 *该* 用

- 用户让你算个东西、你拿不准的：直接跑，不要瞎编。
- 用户粘了一段结构化数据（CSV / JSON / 时间字符串）让你处理：用 pandas / json 跑。
- 想验一个事实、查一组数：用 `httpx` 拉一下原始接口比口头编强。
- 想给用户看个例子、做个 sanity check：5 行 numpy 比脑内推一遍可靠。
- 用户想要一张图：`matplotlib.pyplot.savefig('/tmp/x.png')`，告诉用户路径，让 ta 知道在沙箱里。

## 什么时候 *不要* 用

- 用户要的是**解释 / 思考 / 表达**，不是计算。代码替代不了你的判断。
- 任务是纯文字 / 语言：聊天就够了。
- 一个简单的算术你已经知道答案。
- 没有明确目标的"我们跑跑看"：先想清楚要验证什么再写代码。

## 用得好的几个习惯

- **打印结果**。机器人只能看到 stdout，所以最后一定要 `print(...)`。
- **小步子**。一次一个概念，不要写大段脚本。出错了再追加一段就行。
- **状态会持续一段**。同一个会话里前面定义的变量、import 通常下次还在；但**不要**依赖跨长时间间隔的状态——idle 1 小时后沙箱可能被回收，下次是干净的解释器。
- **错误就是错误**。返回 `exit_code != 0` 时，stdout 里有 traceback，读完直接改，不要道歉绕弯。
- **别污染沙箱**。下载大文件、装额外包、写到处都是的临时文件，用一次没问题，习惯性这样就乱了。
$body$
WHERE NOT EXISTS (
  SELECT 1 FROM pendingbot.skills
  WHERE owner_id IS NULL
    AND bot_id IS NULL
    AND frontmatter->>'name' = 'code-runner'
);

COMMIT;
