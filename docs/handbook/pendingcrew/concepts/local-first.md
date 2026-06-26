# 本地为家(local-first)

> PendingCrew 的部署立场:**本地恒可用,登录是可选的能力叠加**。这台机器是 crew 的「家」,云端只是邮差。本篇是这条立场的权威定义。相关:[运行位置与 Machine](runtime-location-and-machine.md) · [跨设备控制](../features/cross-device-control.md) · [device grant](../../shared/concepts/device-grant.md)。

## 逻辑

PendingCrew 是一个**可以独立开源、自包含**的本地工作台,形态参照 Claude Code / Codex(只为帮人理解长什么样,不是对标):本地 CLI/app + 可选云环境 + 移动端遥控。

- **本地恒可用,不依赖 PendingBot 后端。** 在 Mac 上,crew + captain + session 全在本地跑(用户自己的 claude/codex 订阅 + 自己的机器)。不登录 PendingBot,核心工作流照样转:建 crew、起 session、群聊白板、captain triage、审批——全是本地的。
- **登录 = 可选的三层能力叠加**,只在登录态启用,且**不改变本地是家**这件事:
  1. **fly 云端执行** —— session 跑云 box 而非本地 Mac;
  2. **移动端遥控** —— 从 PendingBot 手机 / iPad 遥控 Mac(或 fly)上的 crew;
  3. **PendingBot 角色入场** —— PendingBot 的 bot / 人类账号作为成员经 edge 信箱加入 crew(社交参与 + 钱包计费)。
- **登录走 scoped grant,不是全权 session。** 想登录时,优先复用本机同发布者 app(PendingBot)的身份:扫码 / 同发布者确认,但 PendingCrew **拿不到 PendingBot 的全权 Supabase session**——它只换到一个受限的 device-grant(`pendingcrew_control` 范围)。共享账号、分开授权、换不出 session。详见 [device grant](../../shared/concepts/device-grant.md)。

**一句话心智**:Mac 上的 `AppModel.backend` 恒为本地后端——登录不会把你切到「云端模式」、本地 crew 不会因登录消失。登录只是把 `isAuthenticated` 这道能力门打开,叠加遥控 / 信箱 / fly。

## 为什么

- **开源软件不能强制登录。** PendingCrew 准备开源,类比 Claude Code 的「登订阅 or 自带 key 二选一」——开源版本必须能不登录任何账号就完整使用。把本地做成自洽核心,而不是「云端的一个瘦客户端」,是这个产品形态的硬约束。
- **本地是家,避免双主同步的坑。** 一个 crew 的通信面(白板 / 群聊 / captain)**同时只托管在一处**:纯本地 crew 用本地白板,登录态 crew 用 edge 白板。**不做本地 ↔ edge 双向 sync**(双主写冲突是个深坑)。要让 PendingBot 的 bot 进 crew 发言,就走一次性「毕业」(把本地 crew 发布到 edge),而不是持续镜像两份。
- **登录最小授权。** 让 PendingCrew 持有完整 PendingBot session 是过权——它只需要「控制 crew」这一小块能力。scoped grant 把授权面收到最小,对齐 MSAL / Google 的同发布者 SSO 模式。

## 用在哪 · 长什么样

- **开机即用,不开屏选模式**:Mac PendingCrew 默认直接进本地工作台,不弹「选模式」。侧栏底部有个「登录 PendingBot 账号」入口,登录是用户主动选的可选动作。
- **登录后侧栏多出账号层**:登录前侧栏只有本机一台机器;登录后会注册本机进机器清单、拉出账号下其它机器(给遥控用)。
- **iPad 是例外——硬登录**:iPad 不能跑本地 coding agent(无子进程能力 + 沙盒限制),所以 iPad PendingCrew 没有「本地为家」可言,它本质是个远程查看 / 遥控端,必须登录才有意义。

## 示例

一个开发者 clone 了开源的 PendingCrew,在 Mac 上跑起来,从没登录过任何账号。他建了个 crew、选 captain 跑 codex、指了工作目录,captain 把任务拆给 worker session,worker `ask` 提问、captain 答、跑完——全程本地,没有一个请求打到 PendingBot 后端。某天他想从手机上看看这个 crew 跑到哪了,于是在 Mac 上点「登录」,扫了下 PendingBot 的码——现在他能从手机遥控这台 Mac 上的 crew 了,但 Mac 上那些 crew 还是本地的家,只是多了一条远程通道。

## 边界

- **不做本地 ↔ edge 双向同步**。一个 crew 的通信面单后端托管;跨界只有「毕业」(本地 → edge,一次性、单向)。降级(edge → 本地)不做。
- **未登录态没有**:fly 云执行、移动遥控、PendingBot bot/人类账号入场、跨设备同步、机器清单(只有本机一台)。
- **本地模式没有 subject / bot / 钱包概念**。本地 crew 成员用本地 id;subjects / 钱包计费只在登录态生效。

## 注意 — 已废的旧模型(别写回)

- ❌ **「双轨配置:登录态 unified billing / 未登录态 BYOK」+ `BackendMode` 枚举** —— 整套**已废**。老 spec(`2026-05-28-…-product-design-v2.md` §5)把 PendingCrew 描述成「登录走统一计费、未登录用户自填 API key(BYOK)」两条并列轨道,代码里有个 `BackendMode.byok` / `.logged` 枚举来回切。**现状:`BackendMode` 枚举已整个删除**;不再有「双轨」,只有「本地为家 + 登录叠加」一条心智。Mac 后端恒本地,登录只翻 `isAuthenticated` 能力门。
- ❌ **BYOK「用户自填 API key 注入子进程」** —— 也已废。子进程**从不**拿 PendingCrew 注入的 API key,直接复用本机已登录的 claude/codex CLI 订阅态(走 `~/.codex` / claude 自己的登录)。key 字段即便残留也是死的(留给未来 SDK / `-p` 额度池可能用),当前不注入。env 卫生详见 [本机子进程安全](subprocess-safety.md)。
- ❌ **「登录即上云 / 本地 crew 镜像到 edge」** —— 被「本地为家、edge 是邮差、单后端 + 单向毕业」取代(2026-06-10 接合 v2 定调)。
