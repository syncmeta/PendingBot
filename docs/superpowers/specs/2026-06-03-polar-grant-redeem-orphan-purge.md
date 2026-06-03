# 送/兑换改走 Polar + 废除老计费路径 — 执行 spec

状态:2026-06-03 落锁,逐单元执行中(`feat/billing-obs-killswitch` worktree)。
用户决策:送(signup)+ 兑换(redeem)都走 Polar;board + 老路径 + 孤儿全废除。

## 已落锁参数
- **新用户 welcome 赠送 = 35 PNC**(= 35_000_000 micros,≈$1.30,等于旧 3500 PND 赠送值原样迁移)。
  - 注意:35 < 50 PNC,启用计费后新用户落"余额低"档(温和提示,不挡);默认 `BILLING_ENABLED=false` 时门禁根本不跑。

## 已验证的 Polar 事实(查 SDK @0.47.1 类型 + 官方文档,非凭印象)
- `customers.create` 入参 `CustomerIndividualCreate`:`email` **必填**,`externalId?` 可选。→ 给从没付过钱的用户发额度必须先建 customer(带 email)。
- 文档未明说 `events.ingest` 用全新 `externalCustomerId` 是否自动建 customer → **不赌**,用 `ensureCustomer` 兜底。
- SDK 非 2xx 抛 `PolarError`(带 HTTP status)→ ensureCustomer catch 409(已存在)幂等,其余 rethrow。
- 现成入账通道 `lib/billing-polar.ts:recordCreditIn(supa, om, {subjectId,kind,source,externalRef,pncMicros})`:幂等账本(`pnc_ledger` unique(source,external_ref))+ `grantCredits`(负值事件)+ 标记 synced。原生支持 `kind:'redemption'|'admin'|'topup'`。**送/兑换都复用它**,只需前置 ensureCustomer。

## 执行顺序(破坏性 drop 放最后、新代码部署之后)
1. **polar-client `ensureCustomer(externalId, email)`** + 单测(纯加,零 prod 风险)。Sdk 结构类型补 `customers.create`。
2. **兑换 → Polar**:
   - 迁移:`billing_redeem` 改为**只**校验+标记 used + 返 `{credits_pnd, code_id}`(删 topups/billing_credit 写)。
   - edge `redeemCode`/`me.ts /redeem`:调新 RPC → `ensureCustomer(userId,email)` → `recordCreditIn(kind:'redemption', source:'redemption', externalRef:code_id, pncMicros: credits_pnd*10_000)` → `wallet.applyAbsolute`/credit 同步缓存。email 从 `pendingbot.users`/JWT 取。
3. **送 → Polar**:
   - 迁移:删 `on_user_billing_signup` 触发器 + `billing_signup_bonus()`。
   - edge:用户首次落地(`/me` 首调,用 `users.signup_bonus_granted` 布尔幂等)→ `ensureCustomer(userId,email)` → `recordCreditIn(kind:'admin', source:'signup', externalRef:'signup:'+userId, pncMicros:35_000_000)`。
4. **删死 edge 代码**:`lib/billing.ts:billingDebit/debitSubject`(无调用)。`getSubjectBalance`/`balance-cache`/`getBalanceGateState` 属 B 段(me.ts/requireBalance 仍用),随 #226。
5. **A 段孤儿 drop 迁移**(见 tech-debt 全清单):表 billing_ledger/group_billing_config/group_billing_custom_shares/ledger_entries/packs/topups/refund_events;RPC billing_admin_grant/billing_credit/billing_debit/billing_debit_subject/billing_issue_codes/billing_v2_admin_adjust/group_set_billing/grp_topup_wallet;触发器 on_user_billing_signup。**redemption_codes 留用**(只换入账)。
6. **部署 worker**(kill-switch 关,安全)。
7. **apply drop 迁移**(`db push`)+ regen schema.ts。
8. **sandbox spike 实测**:对全新 externalId 跑 ensureCustomer+grant+getBalance,确认送/兑换端到端(沿用 P0 spike 纪律)。

## 不在本批(单独收口)
- B 段 `group_member_billing`(invite 流 + iOS 邀请预览)+ `subject_wallets`(me.ts)解耦 = #226。
- topup PostHog 事件改接 Polar/RC = #228。
