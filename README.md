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
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/github/license/syncmeta/PendingBot?color=blue" /></a>
  <a href="https://bun.sh"><img alt="Bun" src="https://img.shields.io/badge/runtime-Bun-fbf0df?logo=bun&logoColor=black" /></a>
  <img alt="TypeScript" src="https://img.shields.io/badge/lang-TypeScript-3178c6?logo=typescript&logoColor=white" />
  <img alt="Platform" src="https://img.shields.io/badge/platform-Web%20%7C%20iOS-lightgrey" />
</p>

<p align="center">
  <a href="README.md">中文</a> · <a href="README_EN.md">English</a>
</p>
知道自己错了的 AI。主动上网冲浪还要处处想着你。

## 主要功能

- 不断回顾、查证你和 AI 之间的对话，不仅是它自己反省，还要批评你，发现你自身认知的错误和局限，让大家都持续进化、变得更好。
- 深挖互联网，主动探索，到处苦苦寻觅对你有价值的、让你眼前一亮的信息。
- 主动地实现上述功能，不是你喊了才动，问一句答一句。

## 两大目标

- **及时复盘、校正彼此** — 免得聊着聊着就被AI带偏、被骗了、不清醒了。当局者迷，旁观者清。
- **探索未知 做信息的 VC** — 缓解一下我们局限的视野和信息茧房

不是助手，不是又一个什么 Agent 什么虾——助手类应用大把人做，我才不重复造轮子。

也不是标准的 AI 陪伴——它不是个听话的宝宝。它是给你带来新视角、新发现的朋友。

下面的内容暂时由 Claude 撰写。

## ✨ 它能做什么

围绕"对话 + 反思 + 探索"三件事，所有动作都不需要你催，到时候它自己会做。

- **🧠 主动聊天** — 默认微信式语气：短句、有停顿，不解释一大堆；也能切回标准 AI 风格。聊到一半你字打得快，它会停一停，不会噼里啪啦把你淹掉。
- **🪞 复盘 / 校正彼此** — 每聊 N 轮，它回头看最近的对话：自己是不是哪里说糊涂了？你是不是哪里有盲区？然后回来跟你讲一讲。
- **🌊 网上冲浪** — 它自己出门，到网上苦苦寻觅对你有价值的、让你眼前一亮的信息，回来挑值得讲的告诉你。可以发 `/surf` 手动触发，也可以让它定期自己跑。
- **🗣️ 一群 Bot 议论你** — 你日常聊天的几只 Bot 拉个群，一起讨论你这个人——像一群朋友背着你聊你一样，多角度的旁观者。
- **🪪 长期画像 / 记忆** — 通过 [Honcho](https://honcho.dev) 持续给你画像、留记忆，影响后续的聊天、反思、冲浪方向。
- **👥 多对多的社交 / 信息网络** — 一只 Bot 可以同时和很多人聊，一个人也可以同时和很多 Bot 聊，Bot 和人交织成网络。朋友之间还能共养同一只 Bot，它会对你们每个人都有印象。
- **🤖 基本的 Agent 能力** — 内置一套 Anthropic 风格的 Markdown skills 当起点，后续会逐步加更成熟的 agent 能力。
- **🔐 BYOK** — 不爽托管方算账，可以填自己的 OpenRouter Key，所有调用走你的额度。

## 💬 用起来什么样

几个具体场景：

- **聊到一半被它叫停**：你和它讨论某个决定，几轮之后它发来："等等，我刚才那一点其实自相矛盾，撤回。"
- **早上打开收到一波冲浪结果**：昨晚开了 autoTrigger，它出门找了一晚上，今天给你抛了三个你没想过的方向。
- **听几只 Bot 背着你聊你**：你日常聊天的几只 Bot 拉个群讨论你的某个抉择，自己旁观——多角度的旁观者。
- **几个朋友共养一只 Bot**：朋友圈里几个人共同养一只 Bot，它对你们每个人都有印象，能把不同人的视角串到一起。
- **自带 Key 重度用 GPT/Claude/Grok**：「我」→ 设置里填 OpenRouter Key，所有模型调用都走你自己的账户。

## 🚀 上手

整仓正在从旧 Bun + Fly 后端切到 Cloudflare Worker + Supabase；目前**没有公开的自部署路径**。能用的只有 iOS app（仍未上架）：

```bash
open apps/ios/PendingBot.xcodeproj
```

首次打开 Xcode 选 Signing Team。

## 📍 进度

毛坯房 · 重写进行中。

- **后端 (apps/edge)** — Cloudflare Worker + Hono + Supabase + R2，刚搭骨架。
- **iOS (apps/ios)** — 几个核心 tab 跑通，登录走 Apple / Google；尚未上架 App Store。
- **Web (apps/web)** — 占位，未启动。

## 🙏 致谢与参考

- **画像与记忆**：[Honcho](https://honcho.dev) ([plastic-labs/honcho](https://github.com/plastic-labs/honcho), Apache-2.0)。
- **Agent Skills 预设** 来自 [anthropic/skills](https://github.com/anthropics/skills)（Apache-2.0），vendored 在 [apps/edge/prompts/skills/anthropic/](apps/edge/prompts/skills/anthropic/)，详见 [NOTICE](apps/edge/prompts/skills/anthropic/NOTICE.md)。
- **运行时**：[Cloudflare Workers](https://workers.cloudflare.com) · [Hono](https://hono.dev) (MIT) · [Supabase](https://supabase.com) · [Bun](https://bun.sh) (MIT, 工具链) · [OpenAI SDK](https://github.com/openai/openai-node) (Apache-2.0) · [Zod](https://github.com/colinhacks/zod) (MIT)。
- **外部服务**：[OpenRouter](https://openrouter.ai)（模型路由）· [Honcho](https://honcho.dev)（画像）· [Cloudflare Sandbox SDK](https://github.com/cloudflare/sandbox-sdk)（沙箱）· APNS。

## 📂 仓库结构

```
PendingBot/                  bun workspaces 单仓
├── apps/
│   ├── edge/                CF Worker + Hono 后端
│   ├── web/                 (占位)
│   └── ios/                 SwiftUI 原生 iOS app
├── packages/
│   ├── core/                跨 Worker 复用的核心逻辑
│   ├── identity/            Supabase JWT + 鉴权 middleware
│   └── shared-types/        共用类型
└── supabase/                migrations / config
```

> 品牌站 `pendingname.com` 在另一个仓库 `syncmeta/PendingName-web`。

## 🤝 贡献

欢迎 Issue 和 PR。提交前简单聊一下想法会更顺利，尤其是提示词 / 冲浪管线 / 跨端协议这类核心改动。

## 📄 License

[MIT](LICENSE)。第三方组件遵循各自原协议（见上）。

---

<p align="center">
  Made with 💚 for people who want a friend that pushes back, not a tool that nods along.
</p>
