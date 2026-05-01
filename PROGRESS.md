# PendingBot 重写 - 进度

**Branch**: `claude/busy-dhawan-5f61ed` (worktree: `busy-dhawan-5f61ed`)
**Plan**: [.claude/plans/pendingbot-rewrite/00-index.md](.claude/plans/pendingbot-rewrite/00-index.md)

## 状态总览

| 阶段 | 状态 | commit |
|---|---|---|
| 计划拆分 + IM/Review/Identity 调整 | ✅ done | (pending commit) |
| B0 — Edge 仓骨架 + Supabase 项目 | ⏳ 等 secrets | - |
| B1 — Postgres schema + RLS | ⏳ 等 secrets | - |
| B1.5 — Worker query 层 + 主路由 stub | ⏳ 待开始 | - |
| iOS Networking 层改造 | ⏳ 待开始 | - |

## 睡前最终拍板的决定

| 决定 | 选择 |
|---|---|
| Supabase region | **us-east-1**（锁死） |
| 附件存储 | R2 保留，不换 Supabase Storage |
| 数据迁移 | 不迁旧 Fly，冷启动重建 |
| Bot cold-start | identity quest meta-prompt（不塞 persona；让 bot 自己追寻独特性） |
| 主键 ID | UUID v7（不用 v4） |
| client_message_id 类型 | uuid（不用 text） |
| 枚举字段 | text + CHECK constraint（不用 PG enum） |
| Review tab | 删除，集成进 message conv |
| IM 预留 | 加 conversation_type / participants 表 / role='human' 占位 |
| bot_reflections + Honcho bot peer | 双源并存，B7 实施时观察是否矛盾 |

## 醒来后请先看

1. 这份 `PROGRESS.md` 看进度概览
2. `VERIFY.md` 逐条验证命令（每个阶段会更新）
3. 如有 `BLOCKED.md` 表示我撞上需要你处理的事
4. `git log --oneline | head -30` 看具体提交

## 我做出的 surprise 决策（偏离计划）

（暂无）

## 等你处理的事

**今晚必备清单**（[09-tonight-checklist.md](.claude/plans/pendingbot-rewrite/09-tonight-checklist.md)）：
- [ ] 创建 Supabase staging project（**us-east-1**）
- [ ] 创建 R2 bucket: `pendingbot-uploads-staging`
- [ ] 创建 KV namespace: `pendingbot-memory-staging`
- [ ] CF API Token
- [ ] OpenRouter API key（顺手充 $5）
- [ ] E2B API key
- [ ] Honcho API key + Workspace ID
- [ ] secrets 写到 `apps/edge/.dev.vars`

我**没有**这些 secrets 时仍然可以推进**本地工作**（脚手架、本地 Supabase、本地 wrangler dev、iOS 代码改造），所以先开干，等你醒来给 secrets 后再做需联网的事。

## B7 时要观察验证的事

- Honcho bot peer `observe_me=true` 派生的 representation 是否合理
  - 跑几轮对话后用 `honcho peer chat bot-${botId} "describe yourself"` 看输出
  - 不合理就回退 false 或改用其它机制
- bot_reflections + Honcho 双源是否产生矛盾的 system prompt
  - 看 bot 行为是否分裂；产生矛盾就改成单一源
