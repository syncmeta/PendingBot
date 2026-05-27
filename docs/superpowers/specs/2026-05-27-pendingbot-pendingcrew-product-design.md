# PendingBot 与 PendingCrew 产品落地设计

日期：2026-05-27
分支：`codex/crew-group-continuation`
状态：待评审

## 目的

这份设计把机组组织模型落到两个产品表面：

- PendingBot：IM 主客户端，类比 ChatGPT。iOS、iPad、Mac 三端都有 Crew tab，用普通群聊 UI 呈现机组。
- PendingCrew：本地 Crew / runner / 编排客户端，类比 Codex。原生 macOS SwiftUI，用来管理机组、项目、本机 runner 和 session 窗口。

两个产品访问同一套机组事实源，但职责不同。

## 产品边界

### PendingBot

PendingBot 是 IM 侧。

它负责：

- 在三端提供 Crew tab；
- 用普通群聊 UI 显示机组；
- 让人类参与机组对话；
- 发送消息、@人、@session、@机长；
- 显示 session 状态卡；
- 显示子机组机长和摘要；
- 进入子机组；
- 从机组消息中触发创建 session 或子机组；
- 展示机组责任主体比例摘要；
- 在需要时打开 PendingCrew 查看 session 细节。

PendingBot 不负责：

- 管理本机 runner host；
- 展示完整执行日志；
- 管理 workspace 权限；
- 直接启动 Codex/Claude/Kilo 进程；
- 管理 Fly Machine 生命周期。

### PendingCrew

PendingCrew 是编排侧。

它负责：

- 展示全局机组 DAG 折叠索引；
- 管理本地项目/workspace；
- 管理 runner host；
- 展示当前机组群聊；
- 展示机组成员、机长、session；
- 展示机组责任主体比例；
- 在右侧显示一个选中的 session 窗口；
- 启动、认领、重试、接管本机 session；
- 展示 session mailbox、事件流、日志和结果；
- 处理人类深度介入。

PendingCrew 不负责：

- 替代 PendingBot 的普通 IM；
- 展示所有普通聊天会话；
- 复制 PendingBot 的完整三端体验；
- 第一阶段自动创建云端 Fly Machine。

## PendingBot Crew Tab

### 信息架构

三端都有一个 Crew tab。

Crew tab 包含：

- 最近机组；
- 我的机组；
- 与我相关的子机组；
- 轻量折叠索引；
- 机组群聊页面。

PendingBot 中的 Crew tab 不需要展示完整 DAG 管理工具。完整 DAG 和项目管理放在 PendingCrew。

### 机组页面

机组页面使用普通群聊 UI grammar。

基本元素：

- 消息流；
- composer；
- @人；
- @session；
- @机长；
- 全员广播；
- session 状态卡；
- 子机组机长成员；
- 子机组摘要；
- 进入子机组；
- 打开 PendingCrew。

机组页面不显示：

- 完整 runner stdout/stderr；
- workspace 文件树；
- runner host 配置；
- session 命令行启动参数；
- Fly Machine 控制台。

### 子机组表现

父机组里显示的是子机组的机长成员。

UI 可以同时显示一张轻量卡：

- 子机组名；
- 机长；
- 状态；
- 最近摘要；
- 进入按钮。

卡片是可视化辅助，不是消息同步机制。真实上传下达由机长消息完成。

### PendingBot 到 PendingCrew

当用户要看 session 细节时：

- iOS/iPad：显示 session 摘要和状态，并提供“在 Mac 上打开 PendingCrew”或复制链接；
- Mac：通过 deep link 打开 PendingCrew 到对应机组和 session；
- 如果 PendingCrew 未安装或未登录，显示安装/登录提示；
- 如果 PendingCrew 没有权限，走正常权限确认。

建议 deep link：

```text
pendingcrew://crew/<crew-id>
pendingcrew://crew/<crew-id>/session/<session-id>
pendingcrew://machine/<machine-id>
```

## PendingCrew 三栏工作台

### 左侧：全局折叠索引

左侧是 PendingCrew 的全局索引。

包含：

- 机组 DAG；
- 最近机组；
- 本地项目/workspace；
- runner hosts；
- machine 预留入口；
- 有求于你；
- 设置。

机组 DAG 支持：

- 展开/折叠；
- 多父节点引用；
- 当前选中机组高亮；
- captain 状态；
- session 运行状态计数；
- 本地/云端 runtime 标识。
- 责任主体比例摘要。

多父节点下，同一个机组可以在多个父节点下面出现引用。引用指向同一个 crew id。

### 中间：机组群聊

中间区域是当前选中机组的群聊现场。

它和 PendingBot 中的机组页面共享同一消息事实源。

它包含：

- 消息流；
- composer；
- @人、@session、@机长；
- 子机组机长成员；
- 机长摘要；
- session 状态卡；
- 创建 session；
- 创建继承式子机组；
- 进入父机组或子机组。

PendingCrew 的中间群聊可以比 PendingBot 多一些编排控件，但视觉上仍然是群聊，而不是 dashboard。

### 右侧：单 session 窗口

右侧一次只显示一个选中的 session。

它根据 session kind 渲染不同工作台：

- `CodexSessionView`;
- `ClaudeSessionView`;
- `KiloSessionView`;
- `CloudSandboxSessionView` 预留。

所有 session view 共享基础结构：

- 任务 brief；
- 当前状态；
- runner kind；
- workspace；
- mailbox；
- 事件流；
- stdout/stderr 或结构化日志；
- 上下文包；
- 最新结果；
- 人类补充指令；
- 重试/接管/停止；
- 回写摘要到机组。

第一阶段不做多个 session 并排。可以有 session 列表和快捷切换，但右侧只渲染一个详情窗口。

## 本地机组执行闭环

第一阶段目标是本地机组可完整跑通：

1. 人类在 PendingBot 或 PendingCrew 创建机组。
2. 机组有机长。
3. 人类或机长创建 session。
4. PendingCrew 的本机 runner host 认领 session。
5. runner 在配置的 workspace 启动 Codex/Claude/Kilo。
6. runner 上报事件、进度和结果。
7. 机组群聊显示状态卡和摘要。
8. 人类可以在群聊或 PendingCrew session 窗口补充指令。
9. session 完成后结果由 session 或机长回写到机组。
10. 如果这是子机组工作，机长向父机组汇报摘要。

## Workspace、权限和责任主体

PendingCrew 管理 workspace 权限。机组可见性、执行授权和成本分摊来自机组解析出的责任主体比例；这个比例和临时群一致，从父机组或创建来源继承。

第一阶段规则：

- runner host 有默认 workspace；
- session 可以绑定 workspace；
- workspace 路径必须在 PendingCrew 中显式配置；
- 机长可以在已有权限范围内创建 session；
- 请求新 workspace 或更高执行权限需要人类确认；
- 修改责任主体比例需要人类确认；
- PendingBot 不直接启动本机 runner。

## 云端预留

云端机组第一阶段只做预留入口。

PendingCrew 左侧可以显示 Machines 分组，但状态为未启用或预留。

预留 UI 信息：

- machine 名称；
- runtime kind；
- 预计成本提示；
- 成本归属的责任主体比例；
- 绑定机组数量；
- 启用云端执行需要确认。

第一阶段不实现真实 Fly API 调用。

## 测试策略

### 组织模型

需要测试：

- 机长 mention target；
- 子机组 captain 加入父机组；
- 父消息不自动进入子机组；
- 多父机组 DAG 去重；
- DAG 环检测；
- 责任主体比例继承和 snapshot。

### PendingBot

需要测试：

- Crew tab 列表加载；
- 机组群聊消息渲染；
- @人、@session、@机长；
- 子机组机长卡片；
- session 状态卡；
- deep link 生成。

### PendingCrew

需要测试：

- 左侧 DAG 折叠索引；
- 中间机组群聊；
- 右侧单 session 窗口；
- session 选择切换；
- workspace 权限提示；
- runner command rendering；
- runner event/mailbox 回填。

验证命令沿用现有 macOS app 路径：

```bash
swift test --package-path apps/macos/PendingCrew
apps/macos/PendingCrew/script/build_and_run.sh --verify
```

## 非目标

第一阶段不做：

- PendingCrew 普通 IM；
- PendingBot 本机 runner 控制台；
- Fly Machine 自动创建/销毁；
- 云端成本自动扣费；
- session 多窗口并排；
- 子机组聊天记录同步到父机组；
- 复杂 merge conflict；
- 通用公司组织架构管理。

## 自检

- PendingBot 和 PendingCrew 职责拆开：一个是 IM 侧，一个是编排侧。
- 三端 PendingBot 都有 Crew tab，但不做 runner 控制台。
- PendingCrew 是原生 macOS SwiftUI 三栏工作台。
- 右侧 session 窗口一次只显示一个选中 session。
- 子机组通过 captain 上传下达，不通过自动消息同步。
- 第一阶段聚焦本地机组，云端只预留。
