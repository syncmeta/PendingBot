<p align="center">
  <img src="docs/app-icon.png" width="128" alt="大绿豆 应用图标" />
</p>
<h1 align="center">PendingBot · 大绿豆</h1>

<p align="center">
  Honest with each other. Curious together. Proactive, candid, a VC for ideas.
  <br />
  <em>不躲，不藏，不绕，不夸。稳稳接住你，还要打开你</em>
</p>
<p align="center">
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/license-MIT-blue" /></a>
  <img alt="Swift" src="https://img.shields.io/badge/lang-Swift-F05138?logo=swift&logoColor=white" />
  <img alt="Platform" src="https://img.shields.io/badge/platform-iOS%20%C2%B7%20iPadOS%20%C2%B7%20macOS-lightgrey" />
</p>


<p align="center">
  <a href="README.md">中文</a> · <a href="README_EN.md">English</a>
</p>

我尽我所能做一些有意思、有人味的 AI 机器人们，以类似微信的形态呈现。

<p align="center">
  <img src="docs/screenshots/main.png" width="820" alt="主界面：左边会话列表，右边正在跟一个机器人聊天" />
</p>

> 还没正式上线。部分功能不可用。

## 快速开始

- **macOS** ——  [Releases](../../releases)
- **iPhone / iPad** —— [TestFlight](https://testflight.apple.com/join/K6Ju9qqP)

## 我精心撰写的文档

<https://docs.pendingname.com/pendingbot>



<table>
<tr>
<td width="50%"><img src="docs/screenshots/contacts.png" alt="通讯录：三个私有机器人，各自挂着不同的模型" /></td>
<td width="50%"><img src="docs/screenshots/letter.png" alt="来信：机器人主动写来的一封信" /></td>
</tr>
<tr>
<td><b>通讯录</b><br>这里比较直观：机器人好友、人类好友，组成社交网络</td>
<td><b>来信</b><br>即时通信软件里写信、收信，别有一番风味<br><sub>和 Email 功能上相同 但味道不同</sub></td>
</tr>
</table>

## 目标

这个App不用来解决什么特定用途。算是一种人文创作，主要就是研究怎样让这些机器人更有人味，以及如何让人能直观地、不依靠文档就能交互。就像三岁小孩知道怎么用iPhone那样。

从功能上来说，我希望里面的机器人：

- **及时复盘、校正彼此** — 免得聊着聊着就被AI带偏、被骗了、不清醒了。当局者迷，旁观者清。
- **探索未知 做信息的 VC** — 缓解一下我们局限的视野和信息茧房

不是助手，不是又一个什么 Agent 什么虾——助手类应用大把人做，我才不重复造轮子。

也不是标准的 AI 陪伴——它不是个听话的宝宝。它是给你带来新视角、新发现的朋友。

## 架构

这个公开仓库只包含 PendingBot 的 **SwiftUI 客户端**。Cloudflare Worker、Supabase
迁移与 RLS、管理后台和部署脚本都不在这里，也不开源。

```text
SwiftUI 客户端（iOS / iPadOS / macOS）
        ↕ HTTP · SSE · WebSocket
Cloudflare Worker → Supabase Postgres
        └────────→ AI Gateway → 模型供应商
```

客户端用同一个 XcodeGen target 编译三端，以 GRDB + SQLCipher 做加密本地缓存；功能界面、
网络层和平台差异分别放在 `Sources/Features`、`Sources/Networking` 与 `Sources/Mac`。

```text
apps/pendingbot/
  project.yml       XcodeGen 工程定义
  Sources/          客户端源码
  Tests/            单元测试
  Resources/        图标、文案与配置
docs/               截图与读者文档
scripts/            构建标记脚本
```

后端坐标集中在 `HostedConfig.swift`。公开版本的托管环境只保留占位配置：源码可以编译运行，
但不会连接 PendingBot 的线上后端。

## 许可

[MIT](LICENSE)

第三方：
- **客户端依赖**（都在 `apps/pendingbot/project.yml` 里）：GRDB.swift（SQLCipher 构建）·
  supabase-swift · GoogleSignIn-iOS · swift-markdown-ui · SwiftMath · posthog-ios ·
  sentry-cocoa · purchases-ios · WebRTC —— 各遵其原协议。
- 后端里 vendored 了 [anthropics/skills](https://github.com/anthropics/skills)（Apache-2.0）
  的 Agent Skills 预设，**那部分不在这个仓库里**；声明与许可以上游仓库为准。
