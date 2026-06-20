# Fly(云端 machine,v1.1)

Fly = PendingCrew 的**云端运行机器**:当用户没有(或不想用)本地电脑跑 coding agent 时,在 Fly 上开一台 box 当 crew 的运行位置,按时长扣责任主体钱包。相关:[运行位置与 Machine](../../pendingcrew/concepts/runtime-location-and-machine.md) · [Runner 后端](../../pendingcrew/features/runner-backends.md) · [跨设备控制](../../pendingcrew/features/cross-device-control.md) · [钱包与 PNC](../../shared/concepts/wallet-pnc.md)。

> 这是 **v1.1 的规划项**,当前只有表结构 + 选择 UI 占位;务必按现状理解(见文末「现状」)。

**逻辑 — 它在系统里扮演什么**

- **一台"云上的机器"** — 在 PendingCrew 的机器清单里,Fly box 和"本机 / peer 电脑"并列,是 `kind=fly` 的一行。某个 crew 引用它,就表示这个 crew 的 coding agent 跑在云端 box 上,而不是用户自己的电脑。
- **与 peer 复用同一套远程通信架构** — 关键洞察:**peer(对等电脑)和 fly(云机器)在架构上是同一种东西**——"一台有进程能力的远程机器,本机只是控制面"。两者共用身份 / 指令转发 / 状态同步 / 审批通道 / 白板注入这一整套。所以把 peer 做通,fly 的通信层就已经铺好;fly 剩下的只是云 API 集成 + 按秒计费 + box 生命周期管理。
- **按秒计费扣钱包** — 本机 / peer 用的是用户自己的设备、算力免费;**fly 是云算力,按运行时长扣对应责任主体(个人 / 群)的钱包**。这是 fly 相对 peer 唯一的计费差异。

**为什么 — 关键取舍**

- **给"没有常驻电脑"的人一条云上的路** — 本地为家是 PendingCrew 的根,但不是每个人都有台一直开着的 Mac;fly 让"手机 + 云 box"也能跑 crew,补齐没有本地机器的场景。
- **顺着 peer 自然延伸,不另起炉灶** — 因为 peer 和 fly 是同一种远程机器,v1 把 peer 通信做扎实后,v1.1 上 fly 只是"换个 runner 宿主 + 接云 API + 按秒计费",过渡格外自然——这也是把"运行位置"做成一等 machine 概念(而非三档死枚举)的回报。
- **算力成本要落到用钱的人头上** — 云机器是真金白银的算力,自然进计费体系(扣 subject 钱包),与 LLM / 语音 / 容器等其它可计费服务同一套门禁 / settle 逻辑。

**用在哪·长什么样**

- 用户感知到的是:机器清单里(本机 / 我的另一台电脑 之外)多一台"云机器"可选;新建 crew 时若有多台机器,能在它们之间选,把 crew 派到 fly 上跑。
- 计费侧:fly box 运行期间按时长周期 settle、扣钱包;余额见底时按计费阈值降级 / 终止(与 sandbox 容器同套逻辑)。

**示例** — 用户没有常开的电脑,只用手机。他在 PendingCrew 里开一台 fly box(进机器清单),新建 crew 时选这台云机器 → crew 的 coding agent 跑在 fly 上,手机当控制面看进度 / 审批。box 运行的每一段时长按秒计入他的钱包消费;不用时关掉 box 停止计费。

**边界 — 明确不做什么**

- **不是默认运行位置** — 默认仍是本机 / 用户自己的设备(免费);fly 是"没有本地机器时"的补充,不抢本地为家的主位。
- **不引入第二套远程机制** — fly 复用 peer 那套通信架构,不为它单开一条独立链路;把它当"另一种 machine"理解,别当"另一套系统"。
- **算力计费仅针对 fly** — 本机 / peer 免费;只有 fly 这台云机器进按时长计费。

**注意 — 坑 / 易错点**

- ⚠️ **当前是占位,不是可用** — 机器表里 fly 行的字段结构 + 新建 crew 的机器选择 UI 已占位,但**开通 / 计费 / 冷启动唤醒 UX 全未做**;别把它当已落地能力描述。
- ⚠️ **"peer ≠ fly 两套机制"是已作废的旧想法** — 它们是同一种远程机器,只在计费(免费 / 按时长)和 box 生命周期(用户开关电脑 / 用户在 app 里开关 box)上不同;任何把它们当两条独立链路设计的说法都已作废。

**现状** — ⬜ **v1.1 规划**。机器清单里 `kind=fly` 的字段结构 + 新建流程的机器选择 UI 已占位(随 machine 概念落地一并进表),但**云 API 集成、box 开通 / 关停、按秒计费、冷启动唤醒 UX 全未实现**。证据见 [运行位置与 Machine 现状表](../../pendingcrew/concepts/runtime-location-and-machine.md)(fly 行 ⬜)+ [`docs/superpowers/specs/2026-06-14-pendingcrew-machine-and-create-flow-design.md`](../../../superpowers/specs/2026-06-14-pendingcrew-machine-and-create-flow-design.md)。
