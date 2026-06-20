# PendingCrew 定位

> 大绿豆里**给开发者**的那一半:一个准备开源、本地为家的 crew 编排工作台,用来编排跑在自己机器上的 coding agent(Claude Code / Codex)。本篇只立**这个产品是什么、为什么是这个形状、开源边界与非目标**——crew / captain / DAG 怎么运作,各自在 `concepts/` / `features/` 里成篇。心智源头在 [党纲](../shared/charter.md);另一半产品见 [PendingBot 定位](../pendingbot/vision.md)。
>
> ⚠️ 这块有一段「双轨已死」的历史,务必按现状理解,别被旧 spec / 旧 roadmap 的「BYOK 双轨」措辞带跑(见文末「注意」)。

## 逻辑 — 这是个什么产品

**PendingCrew 是一个独立、准备开源、本地为家的 crew 编排专业工作台。** 对标 Claude Code Desktop / Codex Desktop 那一档——给「想用 AI 写代码 / 干事」的开发者用的桌面客户端。它编排的是一组 **crew**:一组群聊 + coding agent 的权限边界,由一个 **captain**(机长)把模糊意图拆成可执行的活、收成几件待你拍板的事(见 [crew](concepts/crew.md) · [captain](concepts/captain.md))。

立场的核心是**本地为家**(权威定义见 [本地为家](concepts/local-first.md)):

- **这台机器是 crew 的「家」,云端只是邮差。** 在 Mac 上,crew + captain + session 全在本地跑——用你自己的 claude / codex 订阅、你自己的机器。不登录任何账号,核心工作流照样转:建 crew、起 session、群聊白板、captain triage、审批,全是本地的。
- **登录是可选的能力叠加,不改变本地是家。** 登录后叠加三层能力:fly 云端执行、移动端遥控(从 PendingBot 手机 / iPad 遥控 Mac 上的 crew)、PendingBot 的 bot / 人类账号经 edge 信箱入场参与(社交 + 钱包计费)。但 Mac 后端**恒为本地**,登录只翻开 `isAuthenticated` 这道能力门。
- **登录走 scoped grant,不是全权 session。** 想登录时优先复用本机同发布者 app(PendingBot)的身份(扫码 / 同发布者确认),但 PendingCrew 只换到一个受限的 device-grant(控制 crew 这一小块能力),拿不到 PendingBot 的全权 Supabase session(见 [device grant](../shared/concepts/device-grant.md))。

## 为什么 — 为什么本地为家、为什么准备开源

- **开源软件不能强制登录。** PendingCrew 准备开源,类比 Claude Code 的「登订阅 or 自带 key 二选一」——开源版本必须能不登录任何账号就完整使用。把本地做成自洽核心、而不是「云端的一个瘦客户端」,是这个产品形态的硬约束。
- **本地是家,避开双主同步的深坑。** 一个 crew 的通信面(白板 / 群聊 / captain)**同时只托管在一处**:纯本地 crew 用本地白板,登录态 crew 用 edge 白板,**不做本地 ↔ edge 双向 sync**。要让 PendingBot 的 bot 进 crew 发言,就走一次性「毕业」(本地 → edge,单向),而不是持续镜像两份(双主写冲突是分布式系统最难维持的形态)。
- **登录最小授权。** 让 PendingCrew 持有完整 PendingBot session 是过权——它只需要「控制 crew」这一小块,scoped grant 把授权面收到最小,对齐 MSAL / Google 的同发布者 SSO 模式。

## 用在哪 · 长什么样

平台分布:**macOS 全功能(本地 + 云端)+ iPadOS 仅云端 crew;iOS 不做 PendingCrew。** SwiftUI 单工程、双 destination,本地 runner 模块用 `#if os(macOS)` 隔离(关键约束:iPad 无子进程能力 + 沙盒限制,跑不了本地 coding agent)。

- **Mac 开机即用,不开屏选模式**:默认直接进本地工作台,侧栏底部有个「登录 PendingBot 账号」可选入口。三栏布局——左栏 crew / 标签索引 + 机器清单,中栏 crew 群聊,右栏单 session 窗口(见 [三栏 UI](features/three-pane-ui.md))。
- **iPad 是例外——硬登录**:iPad 不能跑本地 agent,本质是个远程查看 / 遥控端,必须登录才有意义。
- **iOS 用户想看 session**:不另做 PendingCrew iOS,而是通过 PendingBot 的 Crew Tab 遥控(@session 发指令、批权限、看状态卡)。深度调试(看完整 stdout/stderr、改工作目录、配 captain)才需要跳到 Mac / iPad 的 PendingCrew。

## 开源边界

- **PendingCrew 准备开源,PendingBot 不开源。** 大绿豆两个产品里,只有这个 crew 工作台走开源路线;普通人那一半(PendingBot)是闭源商业产品。
- **开源的硬约束 = 不登录也能完整用。** 这条直接决定了「本地为家」的产品形态:本地必须自洽,登录只是叠加。任何把核心工作流绑死在 PendingBot 后端的设计,都和开源边界冲突。
- **登录态的能力(fly / 遥控 / bot 入场 / 钱包)是 PendingBot 生态的增值层**,不是开源核心的一部分——开源用户用不到这些,但本地工作流不缺一块。

## 核心非目标

- **不做 PendingCrew iOS。** iOS 上看 crew 走 PendingBot 的 Crew Tab 遥控。
- **不做普通 IM。** 所有 IM 在 PendingBot;PendingCrew 只有 crew 内部群聊。
- **不做本地 ↔ edge 双向同步。** 通信面单后端托管,跨界只有一次性单向「毕业」(本地 → edge);降级(edge → 本地)不做。
- **不做沙盒 / seatbelt 进程隔离。** v1 对本地 agent 完全信任,只做最小 env 卫生(见 [本机子进程安全](concepts/subprocess-safety.md))。
- **不做通用企业 RBAC、不做 session 多窗口并排、不设 session timeout 上限。**

## 与 PendingBot 的边界

**主 + 辅,一个母题两个入口。** 同一个「人与 AI 协作」的母题,普通人走 IM(PendingBot),开发者走 crew 编排(PendingCrew)。接缝是:PendingBot **看见** crew、做轻量遥控,PendingCrew **深度操作** crew。两者共享同一套[身份地基](../shared/concepts/subject.md)、计费和基础设施,功能不互相吞:PendingBot 不做 runner 控制 / DAG 索引 / machine 管理,PendingCrew 不做普通 IM。

## 注意 — 已废的旧模型(别写回 / 别按它实现)

- ❌ **「双轨配置:登录态 unified billing / 未登录态 BYOK」+ `BackendMode` 枚举** —— 整套**已废**。老 spec(`2026-05-28-…-product-design-v2.md` §5)与 v1.0 实现路线图(Phase 5「BYOK + 整合」)仍把 PendingCrew 写成「登录走统一计费、未登录用户自填 API key」两条并列轨道。**现状:`BackendMode` 枚举已整个删除**,不再有「双轨」,只有「本地为家 + 登录叠加」一条心智(2026-06-10 接合 v2 定调,见 [重大转向史](../shared/evolution/pivots.md) §3)。读到旧 spec / roadmap 的「双轨 / BYOK」措辞,默认它已掉头。
- ❌ **BYOK「用户自填 API key 注入子进程」** —— 也已废。子进程从不拿 PendingCrew 注入的 key,直接复用本机已登录的 claude / codex CLI 订阅态。
- ❌ **「登录即上云 / 本地 crew 镜像到 edge」** —— 被「本地为家、edge 是邮差、单后端 + 单向毕业」取代。
- ❌ **captain = 一个 edge bot 编排器** —— captain 现在是一个被打机长标记的**本地 session**(技术接口不特殊),edge-bot-当-captain 的整套编排面已实删(见 [pivots](../shared/evolution/pivots.md) §4 · [captain](concepts/captain.md))。

## 现状

🟨 **本地核心可用,登录叠加层多数代码已落、真机有尾巴。**

- ✅ **本地为家心智落地**:`BackendMode` 删除、Mac 后端恒本地、不开屏选模式、登录降为可选入口;本地工作流(建 crew / 群聊 / captain / 审批)本地逻辑通,双 build 绿。
- ✅ 本地 crew 闭环:Claude Code 留交互式终端、Codex 走 `codex app-server` 结构化客户端,均已合 main、本机真机验过(见 [runner 后端](features/runner-backends.md))。
- 🟨 **scoped grant SSO 登录**:edge mint 端点 + 共享 keychain 凭据 + 同发布者确认卡代码全落、单测绿,但 Apple/Google 直登与共享 keychain 跨 app 真读需 Xcode GUI 签名验——邮箱 OTP + 扫码已是可用路径。
- 🟨 **登录叠加(遥控 / 信箱 / 毕业)**:控制面代码已落、viewer 读真机验过;实时推命令、「毕业」一次性迁移、两设备 E2E QA 仍是公开尾巴。
- 🟡 **crew DAG / 责任分账的本地化仍有 edge-first 残留**,待续收口(见 [路线图技术债 top](../shared/evolution/roadmap-and-status.md))。
