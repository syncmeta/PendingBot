# PendingBot Mac

这是 PendingBot 的原生 macOS 客户端入口，面向 Crew / coding agent session / runner host 管理场景。

## 定位

- 使用 SwiftUI 原生 macOS 应用形态构建，不走 Mac Catalyst。
- Crew 是调用 coding agent session 的临时群入口。用户只有进入 Crew，才会触发本机或云端 runner 能力。
- iOS 和 macOS 在产品概念上共用 Crew；区别是 iOS 不能直接本地运行 coding agent，但可以在 Mac 在线时作为遥控器使用。
- 当前工程先建立 macOS 端基础壳、登录配置、Crew 列表、session 事件、runner host 和“有求于你”入口。

## 当前能力

- 配置 API 地址和登录 JWT，并把 JWT 存到 Keychain。
- 读取当前 subject，用于确认个人账号或群账号归因。
- 创建和查看 Crew。
- 在 Crew 内创建 session，并查看 session event。
- 注册和心跳 runner host。
- runner host 可以认领一个排队中的 Crew session、上报结构化进度事件、把 session 标记为完成或失败。
- 查看并处理机器人发起的“有求于你”请求。

## 还没有做

- 手机扫码登录。
- 群账号登录到 Mac 的完整流程。
- 本机 Codex / Claude Code / opencode 等 runner 进程启动、权限隔离和日志采集。
- 云端 Cloudflare Sandbox runner 的执行适配。
- 与现有 iOS target 的共享 UI / 共享客户端抽象。

## 构建

```bash
swift build --package-path apps/macos/PendingBotMac
```
