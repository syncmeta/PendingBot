# PendingBot 重写 - 进度

**Branch**: `claude/busy-dhawan-5f61ed` (worktree: `busy-dhawan-5f61ed`)
**Plan**: [.claude/plans/pendingbot-rewrite/00-index.md](.claude/plans/pendingbot-rewrite/00-index.md)

## 状态总览

| 阶段 | 状态 | commit |
|---|---|---|
| 计划拆分 | ✅ done | (此前回合) |
| 工具 lock | 🔵 进行中 | - |
| B0 — Edge 仓骨架 + Supabase 项目 | ⏳ 待开始 | - |
| B1 — Postgres schema + RLS | ⏳ 待开始 | - |
| B1.5 — Worker query 层 + 主路由 stub | ⏳ 待开始 | - |
| iOS Networking 层改造 | ⏳ 待开始 | - |

## 醒来后请先看

1. 这份 `PROGRESS.md` 看进度概览
2. `VERIFY.md` 逐条验证命令（每个阶段会更新）
3. 如有 `BLOCKED.md` 表示我撞上需要你处理的事
4. `git log --oneline | head -30` 看具体提交

## 我做出的 surprise 决策（偏离计划）

（暂无）

## 等你处理的事

**今晚必备清单**（[09-tonight-checklist.md](.claude/plans/pendingbot-rewrite/09-tonight-checklist.md)）：
- [ ] 创建 Supabase staging project（us-east-1）
- [ ] 创建 R2 bucket: `pendingbot-uploads-staging`
- [ ] 创建 KV namespace: `pendingbot-memory-staging`
- [ ] CF API Token
- [ ] OpenRouter API key（顺手充 $5）
- [ ] E2B API key
- [ ] Honcho API key + Workspace ID
- [ ] secrets 写到 `apps/edge/.dev.vars`

我**没有**这些 secrets 时仍然可以推进**本地工作**（脚手架、本地 Supabase、本地 wrangler dev、iOS 代码改造），所以先开干，等你醒来给 secrets 后再做需联网的事。
