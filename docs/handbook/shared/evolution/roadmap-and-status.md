# 路线图与现状

> 这一篇是**地图,不是账本**。它给一个产品决策者需要的全局视野:v1.0 必交付有哪几块、现在整体到哪了、最大的几个结构风险是什么。**精确的"做没做"以 Task 系统为准、"现在真实到哪"以 `docs/progress.md` 为准、风险细节以 `docs/tech-debt/` 为准** —— 本篇只做指针 + 蒸馏,不复制它们的逐条流水,否则必然漂移。
>
> 重大产品转向(为什么从 A 变成 B)单独成篇:[重大转向史](pivots.md)。

## 逻辑 — v1.0 在做什么

大绿豆 v1.0 是**两个产品一次发**:[PendingBot](../../pendingbot/vision.md)(普通人的三端主动 AI 朋友 IM)+ [PendingCrew](../../pendingcrew/vision.md)(开发者的 crew 编排台)。两者共享一套[身份地基](../concepts/subject.md)、[计费](../concepts/billing-subject.md)和基础设施,所以路线图按**共享地基 → 各自功能**的顺序推进,而不是两条独立产品线并跑。

v1.0 的范围由一份实现路线图(`docs/superpowers/plans/2026-05-28-v1-0-implementation-roadmap.md`)切成 6 个 phase、20+ 个 task:

| Phase | 主题 | 这一阶段产出什么 |
|---|---|---|
| 0 | 基础建设 | 三端 / 双端 SwiftUI 工程脚手架(PendingBot iOS+iPad+Mac、PendingCrew iPad+Mac) |
| 1 | 身份地基 | Subject + 群账号权限矩阵 + 扫码登录 + PendingBot 三端 IM 基础壳 |
| 2 | Crew 核心 | Crew / Captain / DAG 责任比例的数据与规则 |
| 3 | 本地 crew 闭环 | PendingCrew 在本机跑通 Claude Code / Codex 一整个 session |
| 4 | 通信 + Bot 扩展 | Session ↔ 群聊通信、权限审批、bot 主动发起 crew、跨端遥控 |
| 5 | BYOK + 整合 | PendingCrew 未登录 BYOK 路径 + 端到端 QA |

原估一人 11–13 周。这是**做事顺序**,不是产品规格 —— 任何产品逻辑细节以本手册各 `concepts` / `features` 篇为准,不以路线图为准。

## 为什么 — 这篇存在的理由

四个账本各管一段,谁都没回答"站在产品高度,这个东西整体到哪了":

- **Task 系统** 答"这个可提交单元做没做";
- **roadmap** 答"计划怎么排、依赖谁";
- **`docs/tech-debt/`** 答"哪里有结构风险 / 关不掉的尾巴";
- **`docs/progress.md`** 答"当前真实状态 + 阻塞 + 下一步"的编年叙事。

本篇是给手册读者的**一页纸入口**:不想翻几百行 progress 也能知道大局,需要深入时顺着指针下钻。所以它**刻意保持薄**,只留会长期稳定的结构性判断,把易变的流水留在账本里。

## 现状 rollup — 整体到哪了

> 下面是**蒸馏后的方向性判断**,带证据指针。逐 task 的精确状态与日期看 `docs/progress.md` §2(v1.0 主线表)和 §3/§4(独立功能 / 计费)。

**地基与本地闭环 — 基本就位。** Phase 0–3 的绝大多数 task 代码已落、多数已验:身份地基(Subject / 群账号 / 扫码登录)、Crew 核心(DAG + 责任比例,带单测)、本地 crew 闭环(Claude Code 留交互式终端、Codex 搬 `codex app-server` 结构化客户端,均已合 main、本机真机验过)都已到 🟨/✅。三端共享 UI(一套 SwiftUI code 跑 iPhone / iPad / Mac,不再 Mac 平行重写)已合 main,Mac 五个 tab 由同一份共享视图渲染。

**通信与跨端 — 代码齐、活验有尾巴。** Phase 4 的 Session ↔ 群聊通信做成了"双向 @ + 看得见发送者 + 可回复 + 全程推送无轮询";跨端遥控(peer_device)的服务端 + runner 链 + viewer 读已真机端到端验过。但**实时推命令(遥控发指令,非只读)**、**两设备 E2E QA**、以及若干"需真账号 / 真机才能 done"的活验,仍是公开尾巴。

**最大的未验区 = 端到端 QA(T5.3)。** BYOK / cloud 全链路**从没真机完整跑通一遍**。这是 v1.0 release-ready 的真实门槛,也是 progress 里唯一标 ❌ 的 roadmap task。pre-launch 单环境、无真实流量,很多"部署冒烟只验了 worker 没炸"的下限验证,都还差一次真消息 / 真通话 / 真账号触发。

**判读规则(重要):** 本手册的 ✅ = **已验证可用**,不是"代码写完"。大量 task 在 progress 里标 completed 但缺真机 / 人工验证,对应到手册一律算 🟨。详见 [`_conventions.md`](../../_conventions.md) 的现状标记表。

## 技术债 top — 最该盯的几个根基风险

> 完整登记在 `docs/tech-debt/`(一债一文件)。这里只列**根基级(🔴)里产品决策者该知道的那几条**,作为指针,不抄全文。状态以 tech-debt 为准。

- **🔴 计费账本 / 权限边界的安全卫生** — pnc 计费账本曾"对 anon 可读、对 authenticated 可改写"(RLS 没开,已修单点),暴露出**"建表习惯性放宽 grant、RLS 没跟上"**是一类系统性风险;另有 service-role 鉴权边界分散、边缘读投影授权门与 RLS 对齐靠人记无测试守护。共同主题:**安全不变量隐式、靠纪律维持,缺红灯**。上线前应把 Security Advisor 跑成准入门。
- **🔴 账号删除级联** — "删一个号能不能成功"依赖手维护的清理触发器 + 每张表的外键 `ON DELETE` 动作 + 一个 Postgres 收敛式 RI 陷阱,**已第二次漂移**:任何新表带个没照顾到的外键就静默让全站删号挂掉,且只有真删才暴露(typecheck 抓不到)。属合规面根基。
- **🔴 welcome bonus 可被 email 别名薅羊毛** — 注册不做 email 规范化,`+` / `.` 别名 = 无限真账号。**开计费前必须堵**(主力 DeviceCheck / App Attest 绑设备,email 规范化当辅助)。现在 kill-switch 关着、未在烧钱。
- **🔴 PendingCrew 的 crew 组织 / DAG 仍部分建在 edge 上** — 违背"本地为家"定调。edge 侧 bot-当-captain 的编排面**已全退役**(2026-06-16 审计实删),但 crew DAG / 责任分账的本地化仍是 edge-first 残留,待续收口。详见 [pivots](pivots.md) 的 captain 心智纠偏一节。
- **🔴(已大部分解决,降级中)旧 credits 计费框架** — 计费事实源 / 成本字段 / 销售 markup 曾混在旧 credits 框架里;随计费引擎外包(Polar + WalletDO),v1 credits 列 + markup 函数族已 drop,降为 🟡。

(注:多账号本地隔离只靠"登出擦库"、`Features/*` 曾被 `#if os(iOS)` 一刀切等 🔴 条目,前者待办、后者已被三端共享 UI 解决,见 tech-debt。)

## 注意 — 别拿这篇当事实源

- **数字会变,本篇不追。** 周数、commit hash、vitest 条数、"未合 / 已合 main"这类易变事实,都在 `docs/progress.md` 里维护;本篇只给方向。看到本篇与 progress 冲突,**以 progress 为准**并回头修本篇(它过时了)。
- **"未合 main"字样在 progress 里曾大面积漂移过** —— 2026-06-16 一次对账发现多个标"未合"的分支其实已合(codex-app-server / crew-machine / model-blindbox / session-crew-comms 等)。这正是"易变事实别进手册"的反面教材:本篇不复制这类标记。
- **roadmap 文档本身是 2026-05-28 的草案**,部分 task 描述(如 captain"三种 / 四种来源"、双轨路由)已被后续转向覆盖,**别照搬 roadmap 的旧措辞**,以 [pivots](pivots.md) + 各 concept 篇为准。
