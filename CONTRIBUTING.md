# 参与 PendingBot

先把期望摆平：**这是一个人的实验项目。** 没有维护团队，没有 SLA，
作者可能几周不看 issue。欢迎你来，但别把它当成一个有承诺的开源项目。

## 在动手之前

- **改动大一点的，先开个 issue 聊。** 直接甩一个大 PR 过来，很可能撞上作者
  没写进仓库的想法，然后白做。小修（打字错误、明显的 bug、文档不准）随手 PR 就行。
- **不接"重构成 X 风格"类的 PR。** 代码怎么组织是作者的口味问题，不是对错问题。
- **安全问题不要开公开 issue**，走 [`SECURITY.md`](SECURITY.md)。

## 开发环境

跑起来的完整步骤在 [`docs/self-hosting.md`](docs/self-hosting.md)。最短路径：

```bash
bun install
bun --filter='@pendingbot/edge' run typecheck
cd apps/edge && ./node_modules/.bin/vitest run    # 695 例
```

Swift 侧：`cd apps/pendingbot && xcodegen`，然后用 Xcode 打开生成的工程。
**新 clone 必须先跑 `xcodegen`**——仓库里不带 committed 的 scheme。

`bun install` 会通过 `prepare` 钩子装上 [lefthook](https://github.com/evilmartians/lefthook)。
它在 commit 前跑两件事：改了迁移就要求同时提交重新生成的 `schema.ts`；
碰了 edge 源码就跑一遍 typecheck。急着提交可以 `LEFTHOOK=0 git commit …` 跳过，
但请只在确实必要时用。

## 提交前请自己跑一遍

CI（`.github/workflows/`）会跑这些，本地先跑能省一个来回：

| 改了什么 | 跑什么 |
|---|---|
| `apps/edge/**` 或 `packages/identity/**` | `bun --filter='@pendingbot/edge' run typecheck` + `cd apps/edge && ./node_modules/.bin/vitest run` |
| `supabase/migrations/**` | `supabase db reset --local`，并重新生成 `apps/edge/src/db/schema.ts` |
| 数据库权限相关 | `bun run db:definer:test`、`bun run supabase:advisor:test` |
| Swift | `xcodegen` 后在 Xcode 里编译 iOS 和 macOS 两个目标 |

**不要提交红的分支。** 如果某项检查你在本机跑不了（比如没有 Apple 开发者账号），
在 PR 里如实说一句你跑了哪些、没跑哪些，这比假装全绿有用得多。

## 迁移

新迁移用时间戳前缀，别自己编号：

```bash
supabase migration new <short_name>
```

理由是多人/多分支并行时四位序号必然撞车。老的 `0001`–`00xx` 保持原样，
Supabase 按字典序执行，`00xx` 排在 `20xx` 前面。

迁移落地之后必须重新生成 TypeScript schema，否则 edge 侧会对着过期的 schema 编译：

```bash
bun --filter='@pendingbot/edge' run types:db
```

## 提交信息

用仓库现有的前缀风格：`edge:`、`ios:`、`db:`、`ci:`、`docs:`、`chore(...)`。
一个提交一件事，别把无关改动塞进同一个提交。

## 语言

代码注释和文档以中文为主，英文也收。变量名、类型名、提交前缀用英文。

## 许可

提交 PR 即表示你同意你的贡献按本仓库的 [MIT 许可](LICENSE) 分发。
