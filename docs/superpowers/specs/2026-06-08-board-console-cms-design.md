# Board Console 重定位 — 内容/预设/配置管理台

**日期**: 2026-06-08
**分支**: `feat/board-console`
**状态**: 设计已认可,待写实施计划

## 一句话

把被废的 "board"(#245 废除)用现有的 `apps/admin` Refine 壳重新长出来 —— 但定位从"运营仪表盘"纠正为**内容/预设/配置管理台**:对现成的 `pendingbot.*` 内容/配置表做 CRUD,经 edge `/v1/board/*`(门禁 + 审计)。前端原来的 8 个运营页全部退役。

## 背景与动机

`apps/admin` 这个 Refine SPA 当前被建错了方向:8 个页面(用户/Bots/会话浏览、计费台账/群池、人工协助/权限审批、管理操作)里,绝大多数职责其实归属别处:

- **用户/会话浏览** → PostHog(persons/events/漏斗/留存,自己写永远更弱)
- **计费台账/钱包发放/追回/退款** → Polar(MoR + 钱包事实源,自带后台)/ RevenueCat(iOS 内购)
- **人工协助/权限审批** → PendingCrew 内部功能(crew/session 级审批),且 PendingCrew 要做成独立开源应用,不该出现在中央后台

真正"只能在中央后台做、PostHog/Polar/Langfuse/Sentry/PendingCrew 都接不住"的,是**内容/预设/配置管理** —— 而这恰好就是被废的 board 原来干的活。board 的**表和运行时读路径全都还在**,只是编辑 UI 随 board 删掉了。本设计 = 把那份编辑 UI 在 Refine 上重建,并补齐 edge 写端点。

## 范围

### 做(四个内容域)

| Board 页 | 源表 | 运行时如何生效 |
|---|---|---|
| 预设机器人 | `pendingbot.bots`(`creator_id IS NULL` 模板行) | onboarding 按用户克隆 |
| 预设会话 / 预设群 | `preset_conversation_templates` / `preset_group_templates` | signup bootstrap 物化 |
| 预设来信 | **新建 `preset_letters`** + 改 `seed_example_letter()` 读表 | signup 注入 self 会话 |
| tool 管理 | `pendingbot.tools` | `tools-registry.ts` 60s TTL 读 |
| KV 配置类 | `mcp_servers` / task-routing / 模型目录 / pricing / i18n / place_names 等源表 | `kvConfig` 读穿表→KV,TTL 自动传播 |

### 不做(归属别处,明确划清)

- 用户/会话/Bots 浏览 → PostHog
- 计费台账/钱包/退款/账号运维 → Polar / RevenueCat
- 人工协助/权限审批 → PendingCrew

## 命名约定

新建的面一律用 **board**,不用 admin:

- edge 路由前缀 `/v1/board/*`,文件 `apps/edge/src/routes/board.ts`
- 前端品牌 "PendingBot Board",resource 路径 `board/preset-bots` 等

**保留 admin 字样的三个底层物件**(已存在,跨切重命名是另一摊 churn,留着复用):

- `pendingbot.users.is_admin` 列(访问判定依据)
- `pendingbot.admin_audit` 表(审计/历史落地)
- `@pendingbot/identity` 的 `requireAdmin()` 中间件

## 架构(三层)

### 1. 前端 `apps/admin`(Refine + Ant Design)

- 加 Refine 官方 Ant Design 集成(`@refinedev/antd` + `antd`)。替换现在手写素 HTML —— 编辑 JSONB 消息数组 / system prompt / tool 绑定需要现成表格/表单/JSON 编辑器/弹窗。
- dataProvider 维持 edge-only(浏览器不直连 Postgres,不放 service-role)。只改 `resource-map.ts`:删旧资源,加新内容域资源,全部指向 `board/*` 且 `exists:true`(端点落地后)。
- `App.tsx` 资源列表 + 路由换成新页;删 `pages/resources.tsx`/`queues.tsx`/`admin-actions.tsx` 里的旧页,换成各内容域的 list/edit 页。

### 2. Edge `/v1/board/*`(新 `routes/board.ts`)

- 挂 `requireSession` → `requireAdmin`(`isAdminLookup = SELECT is_admin FROM pendingbot.users WHERE id = ?`)。
- 每个资源标准 list / get / create / update / delete。
- 写用 service-role client。**每次写操作 = 读 before 快照 → 应用变更 → 写 `admin_audit`**:`{ actor_id, action, target_kind, target_id, before, after, ip, user_agent }`。封装成一个 `boardWrite(c, {targetKind, targetId, action, mutate})` helper,所有资源复用,审计不可被某条路径遗漏。
- 列表响应沿用现有约定 `{ items: [...] }`(dataProvider 已能 normalise)。

### 3. 数据层

- 全部复用现成表,**唯一新建** `preset_letters`(预设来信),并把 `seed_example_letter()` 改为从该表读取信件内容(而非函数内写死)。其余域零迁移。
- KV 配置类:`kvConfig` 是"读穿源表 → 缓存 KV → TTL 过期重读"。board 改源表后,KV 在既有 TTL 窗口内自动刷新 —— **不需要单独 KV 写路径**。可选:给写操作加一次显式 KV purge,把传播从"≤TTL"压到"即时"。

## 历史 / 版本

走现有 `admin_audit` 表,列已齐(`action / actor_id / before / after / target_kind / target_id / ip / user_agent / created_at`),**零新表**。每次 board 写落一条带 before/after JSON 的审计,即数据库侧的修改历史;回滚 = 人工把 before 值粘回(暂不做一键回滚)。

## Admin 引导(bootstrap)

`requireAdmin` 依赖 `users.is_admin`,当前可能无任何 `is_admin=true` 用户。实施时提供一条 SQL 把指定账号设为 admin:

```sql
UPDATE pendingbot.users SET is_admin = true WHERE id = '<user-uuid>';
```

(由用户本人在场确认后对共享 DB 执行。)

## 分期(各自独立、可单独上线)

- **P0 框架**:edge `routes/board.ts` 脚手架(requireAdmin 注入 + `boardWrite` 审计 helper)+ 前端接 AntD + 删旧页 + admin bootstrap SQL。
- **P1 预设机器人**(最高频):`bots` 模板行 CRUD。
- **P2 预设会话/群 + 预设来信**:含 `preset_letters` 小迁移 + `seed_example_letter()` 改读表。
- **P3 tool 管理**:`tools` 表开关 / 绑定 / `model_description` 编辑。
- **P4 KV 配置类**:逐个配置源表(先 `tools-registry`/`mcp_servers` 已确认走 kvConfig 的,再钉模型目录/pricing/i18n/place_names 的确切源表)。

## 待实施时钉死的开放项

1. **KV 配置类的确切源表**:目前只确认 `cfg:tools-registry`、`cfg:mcp-servers` 真走 `kvConfig`。models/pricing/i18n/place_names(#263 "config → KV")的源表/读路径需在 P4 计划阶段逐个核实,可能部分不在 `kvConfig` 通道而需单独接。
2. **预设来信抽表**:`seed_example_letter()` 的现有信件内容结构(单封"读我" vs 可多封),决定 `preset_letters` 的列设计。
3. **KV purge 即时性**:P4 决定是否给写操作加显式 KV 删除,还是接受 ≤TTL 的传播延迟。

## 验证

- Edge: `bun --filter='@pendingbot/edge' run typecheck` + vitest(board 路由的 requireAdmin 门禁 + audit 落地单测)。
- 前端: `cd apps/admin && bun run build` 绿。
- 端到端: 用 is_admin 账号登录 board,对每个域做一次增删改,确认 (a) 运行时生效(克隆/TTL 刷新)(b) `admin_audit` 落了 before/after。
- 迁移: `supabase db push` + `bun --filter='@pendingbot/edge' run types:db` 后 typecheck。
