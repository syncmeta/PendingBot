# PendingCrew 侧栏三件套：机长改名意识 · 实时最新消息 · 头像状态点

日期：2026-07-06 ｜ 状态：已过用户确认（对话中三段全 OK）｜ 范围：Mac PendingCrew

## 背景与问题

1. **机长改名意识不足**。`rename_crew` 工具已存在（McpServer → LocalCrewControlStore 文件通道 → CrewStore 应用），但 captain prompt 教的是「一两次就够，别反复改」，且机长只有启动时知道 crew 名字——改名后/长 session 中它不知道当前名，也就无从判断名字是否还贴切。
2. **侧栏最新消息不实时**。`CrewDAGNode.lastMessagePreview`（CrewDAGTreeView.swift）每次 render 同步读 `LocalWhiteboardStore.shared`，但视图不订阅白板变化——只有点选 crew 引发重渲染时才刷新。
3. **没有 crew 级状态点**。session 级信号已齐（`SessionBackend.isWorking`、`health: CrewSessionHealth?`、`status == .exited`），但侧栏 crew 行看不到任何运行状态。

用户决策（对话确认）：

- 改名：**机长自主判断**何时改；系统只保证它「时刻知道当前名字 + 有改名工具」，不规定时机。
- 黄点：**不绑定固定信号**，由机长主动点亮/熄灭（有问题/待决策时提示用户）；熄灭 = 机长自己撤，或用户回复后机长判断撤。
- 状态点位置：头像右上角。优先级 红 > 黄 > 绿 > 灰。

## 设计

### 1. 机长改名意识

- **每轮注入当前名**：白板每轮注入通道（claude PostToolUse hook / codex turn 前注入，共用同一 provider，见 `CrewSessionRunner`）的头部加一行「本 crew 当前名：〈title〉」。机长（及成员）因此每轮都看到当前名字。
- **Prompt 改词**（`apps/pendingcrew/Resources/Prompts/crew-captain.zh.md` 命名条）：删掉「一两次就够，别反复改」，改为「名字是活的——crew 的主题演进了就随手 `rename_crew` 改成贴切的短标签；人类自己起的有意义名字别动」。
- `rename_crew` 工具与文件通道不动。

### 2. 侧栏实时最新消息（方案 A）

- `CrewStore` 已订阅 `LocalWhiteboardStore.directoryChanged`（改名监听同款）。新增一个 `@Published private(set) var whiteboardRevision: Int`，目录一变就 +1。
- 侧栏行已 `@EnvironmentObject var crewStore`；行内读一下 revision（或把 preview 改成经 crewStore 的读函数）即可让白板变化触发全侧栏行重渲染，`lastMessagePreview` 重新求值。
- 不把 `LocalWhiteboardStore` 改成 ObservableObject（方案 B 被否：每行挂观察者、视图直接依赖共享单例）。
- 远端机器的 crew 行没有本地白板，维持现状（显示「还没有消息」/空）。

### 3. 头像右上角状态点

**数据模型 / 聚合**（crew 级，取最高优先级）：

| 色 | 条件 | 来源 |
|---|---|---|
| 🔴 红 | 任一 session `health != nil`（未登录/额度到顶/调不了模型——crew 自己解决不了的错） | `SessionBackend.health` |
| 🟡 黄 | 机长点亮的 attention flag | 新 MCP 工具（下） |
| 🟢 绿 | 任一 session `isWorking` | `SessionBackend.isWorking` |
| ⚪️ 灰 | 其余（无 session / 全空闲 / 已退出） | — |

**机长 attention 工具**（照 `rename_crew` 的文件通道模式）：

- `raise_attention(reason)`：点亮本 crew 黄点，reason 为一句话说明（必填）。
- `clear_attention()`：熄灭。
- 通道：McpServer 新 tool → `LocalCrewControlStore` 写请求文件 → `CrewStore` 监听目录变化应用 → 持久化到 `LocalCrewStore`（crew 记录加 `attentionReason: String?` 字段，app 重启不丢）。
- Prompt：crew-captain.zh.md 新增一条教机长——需要人类决策/遇到自己解决不了的事就 `raise_attention`，事情解决（含用户已回复且不再需要）就 `clear_attention`。

**渲染**：

- `CrewDAGNode` 行内 `CrewGroupAvatar` 右上角 overlay 一个小圆点（约 10pt，带背景色描边，样式对齐 roster/切换条现有状态点 `CrewSessionWindowView` 的画法）。
- 黄点 hover tooltip 显示 `attentionReason`；其他色不带 tooltip（或红点 hover 显示 health detail，实现顺手就做）。
- 灰点在「无任何 session 记录」时可不画（避免所有闲置 crew 都挂灰点造成噪音）——有过 session 但全退出/空闲时画灰。
- session 状态源：观察 `CrewSessionRunner`（app 内已有 published runs / snapshot），不读 crew-sessions.json 文件。

**范围**：Mac 侧栏（LocalRunner 只在 macOS）。iPad / 远端机器 crew 行不画点，随遥控投影（#242）再说。

## 测试

- LocalCrewControlStore attention 请求读写/清除单测（对齐 rename 现有单测）。
- LocalCrewStore attention 持久化单测。
- 聚合优先级纯函数单测（红>黄>绿>灰）。
- `xcodebuild test`（PendingCrew Mac scheme）+ Mac build；模拟器/真机活体验证归 GUI QA 批次（#443）。

## 不做

- iPad / iOS PendingBot 端状态点与实时预览（无本地 runner）。
- edge/DB 改动——全部纯本地。
- 黄点的自动推导（审批待批/@未读等）——语义归机长。
