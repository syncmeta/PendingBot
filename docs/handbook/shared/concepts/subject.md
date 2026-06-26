# Subject(责任主体)

**Subject 是大绿豆里"谁负责"的统一抽象。** 一个 crew、一个会话、一个 bot、一台 runner、一台云端 machine —— 凡是会**花钱、被看见、需要批准**的东西,背后都钉着一个 subject。问"这笔 token 谁付""这个 crew 谁能进""这个高风险操作谁能批",答案永远是"看它的责任主体"。

这一篇立的是**账号模型本身**。群账号的轻量定位、群权限的三级矩阵、计费怎么扣,各有专篇:[群账号](group-accounts.md) · [群权限矩阵](group-permissions.md) · [`billing-subject`](billing-subject.md) / [`group-pledge`](group-pledge.md) / pendingcrew [`dag-and-responsibility`](../../pendingcrew/concepts/dag-and-responsibility.md)。

## 逻辑 —— 两类 subject

Subject 只有两类,没有第三类:

- **`user_account`(个人账号)** —— 一个真人一个,注册即自动有,永远恰好一个。这是默认责任主体:你自己用大绿豆、自己开一个 crew、你的 bot,费用和权限都归你的 user_account。
- **`group_account`(群账号)** —— 一群人共担的责任主体。几个人合用一个钱包、共管一批 crew、共同决定谁能批准操作,就建一个群账号(定位见 [群账号](group-accounts.md))。

每个 crew / 临时群 / 会话 / runner host / 云端 machine,都绑**唯一**一个 `responsible_subject_id`。这一个字段同时回答三个问题:

1. **谁付钱** —— 费用从这个 subject 的钱包扣;
2. **谁可见** —— 谁有权看见、进入这个资源;
3. **谁批准** —— 谁能拍板高风险操作(改责任比例、开云端 machine、接受跨主体协作)。

把"付钱 / 可见 / 批准"绑成同一个主体,是这个体系最核心的设计:它们本就该是同一个主体,拆开就会出现"A 付钱但 B 能看""谁都能花但没人能批"这类裂缝。

## 为什么 —— 把"责任"从"用户"里拆出来

最朴素的做法是一切都挂在 user 上:bot 是某个 user 的、会话是某个 user 的、费用从某个 user 扣。但大绿豆是**人与 AI 协作的平台**,协作天然会出现"这批东西不属于某一个人,而属于一群人":一个旅游小队合伙整理行程、一个家庭共用一台 Mac、一个公司项目组合管一批 crew。

如果不抽象出 subject,这些场景就得在每个挂"user"的地方临时打补丁("这里也可能是个群")。抽出 subject 后,**下游所有东西只认 `responsible_subject_id`,不关心它背后是一个人还是一群人**——计费、权限、审计的代码路径对两类 subject 完全一致。这是"先有干净的责任主体地基,再在上面长 crew / 协作 / 计费"的根本原因。

## 边界

- **没有第三类 subject** —— 就 user_account / group_account 两类,不引入"组织 / 部门 / 角色"等更重的概念。
- **`responsible_subject_id` 是责任的单一入口** —— 任何新增的"会花钱 / 被看见 / 需批准"的对象,都必须绑一个 `responsible_subject_id`,不再临时挂 user。
- **责任比例不在账号模型里** —— 单个 subject 内部没有"比例"概念;"比例"出现在 crew 的 DAG(一个 crew 可能由多个 subject 按比例共担),那套规则归 pendingcrew [`dag-and-responsibility`](../../pendingcrew/concepts/dag-and-responsibility.md)。

## 注意

- **历史回填** —— user_account 是从原有的纯 user 模型回填来的:每个老用户补一个 user_account subject,触发器保证新用户注册即有。
- **schema 里有两套字段名是别名,不是两个概念** —— `subjects` 表既有新名 `kind` 也有旧名 `subject_type`,以 `kind` 为准;旧名留作 alias 是为了不断老代码引用,别误以为是两种分类。详见 [`subject-foundation.md`](../../../superpowers/plans/2026-05-24-subject-foundation.md) 的 Spec v2 修订节。
- **计费栈别按废弃路径找** —— subject 的钱包**不再**是早期的 `subject_wallets` 表 / billing-v2 自研结算引擎,那套已退役。现在责任主体维度的余额事实源是 **Polar + WalletDO + PNC**(见 [`billing-subject`](billing-subject.md) / [`wallet-pnc`](wallet-pnc.md))。老 spec / 老 plan 里写的 `subject_wallets`、`billing_debit_subject` 都是 billing-v1 的残影,schema 里残留的 `subject_wallets` 是僵尸快照、早已不被扣减。
