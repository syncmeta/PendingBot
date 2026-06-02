# 计费 P2：用量计量 + 门禁(WalletDO)Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development 或 superpowers:executing-plans。

**Goal:** 把 Polar 计费接进 LLM/语音/web/sandbox 主链路:调用前读 **WalletDO** 缓存余额做门禁(4 档阈值),调用后按真实成本扣 DO 余额 + 缓冲用量、由 DO 周期 flush 到 Polar;退役 billing-v2 本地账本。

**Architecture(定案见 [`../specs/2026-06-02-billing-p2-architecture-fork.md`](../specs/2026-06-02-billing-p2-architecture-fork.md)):** Polar=钱包事实源;**WalletDO(每 subject 一个)= 强一致缓存 + 门禁闸 + 用量 outbox**;全 push 同步(`customer.state_changed` + edge push)+ 稀疏对账兜底。**DO 不是账本**——只 `balanceMicros` + `pendingUsage[]`。

**Tech Stack:** CF Workers + Durable Objects(SQLite storage)+ Hono + `@polar-sh/sdk` + vitest(@cloudflare/vitest-pool-workers 支持 DO 测试)。

> **依赖**:P0(polar-client)+ P1(入账 webhook + pnc_ledger)已完成。本计划**先全部出来供评审**,再执行。

---

## 文件结构
- Create: `apps/edge/src/durable-objects/wallet.ts` —— `WalletDO`(核心)。
- Create: `apps/edge/src/durable-objects/wallet.test.ts`
- Create: `apps/edge/src/billing/wallet-client.ts` —— 从 Worker 调 WalletDO 的薄 helper(routing by subjectId + gate/debit/credit RPC)。
- Create: `apps/edge/src/billing/cost.ts` —— `vendorUsd → pnc_micros` + pricebook(复用 P0 `pnc.ts`;web_tool_prices 已有)。
- Modify: `apps/edge/wrangler.jsonc` —— 加 `WALLET` DO binding + migration。
- Modify: `apps/edge/src/types.ts` —— `Env.WALLET: DurableObjectNamespace`。
- Modify: `apps/edge/src/index.ts` —— export WalletDO class。
- Modify: `apps/edge/src/llm/router.ts` —— `enqueueAudit` 前置 gate / `persistAuditMessage` 改调 DO debit+flush(替 `settleTurnV2`)。
- Modify: `apps/edge/src/durable-objects/realtime-meter.ts` + `room-voice.ts` —— 语音 gate+debit 走 DO。
- Modify: `apps/edge/src/routes/billing-webhooks.ts` —— 加 `customer.state_changed`;P1 入账后 push DO。
- Modify: sandbox/code-exec 路径 —— 新增 gate + settle。
- Retire: `lib/billing-v2.ts settleUsage` 调用点 + `billing-v2-dualwrite.ts`(packs/ledger 扣减);保留 `billing-v2-group.ts`(share-index)、`pnc_ledger`(转审计)。

---

## Phase A — WalletDO 核心(TDD)
**职责**:强一致余额 + 门禁 + 用量 outbox。DO SQLite 存 `balance_micros`、`pending_usage(id, pnc_micros, category, meta, created_at, flushed)`、`last_reconcile_at`、`initialized`。

- [ ] **A1** wrangler.jsonc 加 `WALLET` DO binding + `new_sqlite_classes: ["WalletDO"]` migration;`Env.WALLET`;index.ts `export { WalletDO }`。typecheck。
- [ ] **A2 RPC 接口(WalletDO)**:
  - `ensureInit(env)`:未初始化则 `polar.getStateExternal` 拉绝对余额写入(惰性冷启动)。
  - `gate(costHintMicros?)`:读余额 → 返回 `{thresholdState: 'sufficient'|'low'|'throttle'|'exhausted', balanceMicros}`(不扣)。
  - `debit(pncMicros, meta)`:`balance -= pnc` + 插 pending_usage(未 flushed)→ 返回 `{balanceMicros, thresholdState}`。**允许扣到 −0.5 PNC overdraft**(spec)。
  - `credit(pncMicros, meta)`:`balance += pnc`(充值/退款 push)。
  - `applyAbsolute(polarBalanceMicros)`:`balance = polarBalanceMicros − Σ(pending 未 flushed 的 pnc)`(回环防双扣,坑#1)。
  - `alarm()`:flush 所有未 flushed pending → `polar.reportUsage`(批量)→ 标记 flushed + 清理;距上次 reconcile 超阈值则 `getStateExternal` 纠偏;重排 alarm。
  - TDD:gate/debit/credit 的余额数学、overdraft、applyAbsolute 减在途、阈值分档、pending 持久(模拟重启)。Polar 调用 mock。

## Phase B — wallet-client + cost(TDD)
- [ ] **B1** `wallet-client.ts`:`walletFor(env, subjectId)` → stub;`gate/debit/credit/applyAbsolute` 包装(`env.WALLET.idFromName(subjectId)`)。
- [ ] **B2** `cost.ts`:`vendorUsdToPncMicros(usd)`(复用 `pnc.ts`,27 PNC/USD)。web_tool/voice/sandbox 单位 → pnc。TDD。
- [ ] **B3** owner→subjectId 解析:复用 `resolveConversationBillingTarget`/`responsible_subject_id`(Explore 已定位 router.ts:500),抽成 `resolveBillingSubjectId()`。

## Phase C — LLM 路径接 DO(替 settleTurnV2)
- [ ] **C1 前置 gate**:`enqueueAudit`(router.ts:288)前,解析 subject → `wallet.gate()`。`exhausted` → 走"余额花完"文案路径(不调用模型);`throttle`(<5 PNC)→ 传信号给 router 用 OpenRouter `cost_quality_tradeoff=max` + 关工具;`low` → 注入低额提醒。系统级级联(title/lookback)跳过 gate。
- [ ] **C2 后置 debit**:`persistAuditMessage`(router.ts:331)成本确认后,`vendorUsdToPncMicros(combinedUsd)` → `wallet.debit(...)`(替 `settleTurnV2`/`settleUsage`)。web tools 每 call 一并 debit。
- [ ] **C3** 删 `settleTurnV2` 调用 + `billing-v2-dualwrite.ts`;`pnc_ledger` 仅留审计写(可选)。typecheck + 测试。

## Phase D — 语音接 DO
- [ ] **D1** 1v1(`realtime-meter.ts` settleTurn:418 / enforceBalance:489):周期 settle → `wallet.debit`;`debit` 后 `exhausted` → `endCall()`。
- [ ] **D2** 群(`room-voice.ts` settleRealtimeKitMediaCost:1113):participant-minute 成本 → `wallet.debit`(群 subject);≤0 → 终止房间媒体。

## Phase E — web tools
- [ ] **E1** web tools 每次调用成本(`web_tool_prices`)→ `wallet.debit(category:'web_tools')`。(随 C2 的 turn settle 一起,按 call。)

## Phase F — sandbox 计费(新,补缺)
- [ ] **F1** 代码执行**前** gate(`exhausted` 拒绝执行);**后**按容器时长/资源 → `vendorUsd→pnc` → `wallet.debit(category:'sandbox_runtime')`;长任务周期 settle,≤0 终止容器。(Explore:sandbox 目前完全无计费,需从容器 DO 拿时长。)

## Phase G — 充值/Polar 变动 push DO
- [ ] **G1** P1 webhook(`billing-webhooks.ts`)`recordCreditIn`/`recordRefund` 成功后 → `wallet.credit/applyAbsolute`(让缓存即时跟随,不等 Polar)。
- [ ] **G2** 新增 Polar `customer.state_changed` webhook 分支 → 取绝对余额 → `wallet.applyAbsolute`(坑#1 减在途)。
- [ ] **G3** 群充资/退群(`billing-v2-group.ts` contribute/refund)→ push 对应群/个人 WalletDO。

## Phase H — 退役 billing-v2 本地账本
- [ ] **H1** 移除 `settleUsage`/packs/ledger_entries 扣减路径(C3/D 已替);保留 `billing-v2-group.ts`(share-index)、`billing-v2-pack.ts` 仅作支付审计(或并入 pnc_ledger)。
- [ ] **H2** 旧 `requireBalance`/`getOwnerBalanceMicros`/`enforceBalance` → 改读 WalletDO(或删,统一走 DO gate)。
- [ ] **H3** 全量 `vitest run` + typecheck;确认无残留 settleUsage 调用。

## Phase I — 验证
- [ ] **I1** DO 单测(Phase A)+ 各路径接线单测。
- [ ] **I2** 真实 sandbox spike(像 polar-verify):建 WalletDO → credit 充值 → gate → debit 多次 → alarm flush → 查 Polar 余额一致 + DO 余额一致 + 阈值分档正确 + overdraft 边界。
- [ ] **I3** 部署 + 烟测门禁端点。

## Self-Review(写计划时)
- **覆盖**:gate+debit 四路径(LLM/语音/web/sandbox)+ 充值/退款/Polar变动 push + 退役旧账本 + 4 档阈值 + 群。坑清单 11 条对应:#1→A2.applyAbsolute/G2;#2→A2.alarm reconcile;#3→DO SQLite;#4→pending 持久;#5→gate 只读 DO;#6→cost.ts 符号;#7→G2 spike 核字段;#8→B3 owner;#9→cost 用 vendor;#10→C1 系统级跳过;#11→延迟可接受。
- **风险**:这是大改 + 动钱主链路。建议分 Phase 提交、每 Phase typecheck+test;Phase H(退役旧账本)最后做,确保新路径先验过。
- **未决(执行时定)**:sandbox 时长成本来源(容器 DO 测量?);`customer.state_changed` 是否每笔用量都触发(影响 alarm vs webhook 谁主导对账)。
