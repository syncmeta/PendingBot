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

## 产品定位（重要）

**单人开发但目标用户体验世界级**：假设多用户场景设计，成本敏感但不极端，UX 优先。代码量不是约束，但维护性是。详见 [11-scale-and-ux.md](.claude/plans/pendingbot-rewrite/11-scale-and-ux.md)。

## 最终拍板的决定

| 决定 | 选择 |
|---|---|
| Supabase region | **us-east-1**（锁死） |
| 附件存储 | R2 保留（CF 边缘 CDN 优势） |
| 数据迁移 | 不迁旧 Fly，冷启动重建 |
| Bot cold-start | identity-quest.md meta-prompt |
| Prompts | 全部 markdown 文件 in `apps/edge/prompts/`（mirror 老 `apps/api/prompts/`），Wrangler text import |
| 主键 ID | UUID v7 |
| client_message_id 类型 | uuid |
| 枚举字段 | text + CHECK constraint |
| Review tab | 删除，集成进 message conv |
| IM 预留 | conversation_type / participants 表 / role='human' 占位 |
| bot_reflections + Honcho 双源 | **辨证演进** —— 矛盾是 feature 不是 bug |
| 暗色模式 | **做**（W0 加） |
| 动效库 | Framer Motion |
| 监控 | Sentry + Cloudflare Workers Observability + Better Stack uptime |
| 缩略图 | R2 上传时同步生成 |
| Push notification | iOS APNS + Web Push API |
| API versioning | URL `/v1/` 大代际 + `X-Client-Version` header 细粒度（学 Stripe） |
| Realtime 订阅 | 分层 channel：常驻 user-level + lazy conv-level；Postgres trigger 维护 `user_unread_counts` |
| 消息编辑 | 链表模型（replaces/replaced_by），不直接改 content |
| conversation_participants | 多态（user/bot 都作为成员），统一 RLS |
| Surf UI | 独立 task panel，Claude Code Desktop 风格 |
| Discuss UI | IM 群聊形态进主消息列表 |
| 品牌 | pendingname.com / PendingBot 已锁定 |
| Sandbox | Daytona（OSS Apache 2.0，managed Cloud 起步；用量稳定后可自托管） |

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
- [ ] Daytona API key
- [ ] Honcho API key + Workspace ID
- [ ] secrets 写到 `apps/edge/.dev.vars`

我**没有**这些 secrets 时仍然可以推进**本地工作**（脚手架、本地 Supabase、本地 wrangler dev、iOS 代码改造），所以先开干，等你醒来给 secrets 后再做需联网的事。

## B7 时要观察的事（不是修复，是观察）

- Honcho bot peer `observe_me=true` 派生的 representation 演化轨迹
  - 跑几轮对话后用 `honcho peer chat bot-${botId} "describe yourself"` 看输出
  - 噪音和矛盾**是预期的**——记录下来作为产品演化的数据点
- bot_reflections + Honcho 双源在 system prompt 里的辨证效果
  - 看 bot 是否真的从矛盾中长出连贯人格（产品差异化）
  - 调整两源的措辞引导（在 system.md 和 review.md 里）让 LLM 更好 reconcile
