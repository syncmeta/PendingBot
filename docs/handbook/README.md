# 大绿豆 生态手册

> 这是大绿豆(**PendingBot** + **PendingCrew**)的**产品事实源**。站在产品 / 决策者的高度写:**产品逻辑 + 为什么 + 边界**,清楚到"照着走,产品策略不跑偏"就够——实现细节交给代码和 stage docs,不进这里。
>
> 与本手册冲突时,以本手册为准。每篇写法见 [`_conventions.md`](_conventions.md)(松散指南,不是死模板)。
>
> **粒度**:一个可独立查找的主题 = 一篇(保持厚度),开发时照目录索引直接定位;一篇里塞了多个并列主题就拆开。

## 怎么读

| 你想… | 看这里 |
|---|---|
| 懂产品怎么想 | `shared/charter` + 各 `concepts` |
| 知道要做 / 做了什么 | 各 `features` |
| 知道系统由什么搭起来 | `shared/stack`(只到"各服务什么角色",不到实现) |
| 知道到哪了 / 为什么变 | `shared/evolution` |

两个产品各成一册,共享的基座单独一册(单一事实源,不重复)。

```
docs/handbook/
├── README.md            本文件
├── _conventions.md      每篇怎么写(模板 + 现状标记 ✅/🟨/⬜)
│
├── shared/              ── 基座:两产品共享 ──
│   ├── charter.md       产品信条 + 红线(工程约定引用根 CLAUDE.md)
│   ├── concepts/        subject · group-accounts · group-permissions · device-grant · data-visibility-rls · avatar-visibility · conversation-types
│   │                    models · billing-subject · wallet-pnc · group-pledge
│   │                    config-as-cms · read-path
│   ├── stack/           系统全景(各服务角色):cloudflare(edge/admin/voice-container/DO/kv/r2/
│   │                    ai-gateway/access) · supabase · apple · anthropic · openai
│   │                    polar · revenuecat · openrouter · langfuse · posthog · sentry · grafana · fly · google
│   └── evolution/       roadmap-and-status · pivots
│
├── pendingbot/          ── 大绿豆:主动 AI 朋友 ──
│   ├── vision.md        定位 + 产品信条 + 非目标
│   ├── concepts/        bot-persona · bot-visibility · bot-social-graph · proactivity · delegation
│   └── features/        information-architecture · proactive-lookback · web-surf · group-bot-discussion
│                        envelope-inbox · add-friend · bot-invites · group-invites · voice · model-blindbox · create-bot-presets · tri-platform-ui
│
└── pendingcrew/         ── 编排工作台 ──
    ├── vision.md        定位 + 产品信条 + 开源边界 + 非目标
    ├── concepts/        crew · captain · dag-and-responsibility · runtime-location-and-machine
    │                    local-first · session-and-world-model · human-in-the-loop · subprocess-safety
    │                    whiteboard · project-cockpit(⬜ 规划,见 task #439)
    └── features/        three-pane-ui · create-crew-and-session · runner-backends
                         session-crew-comms · cross-device-control
```

---

**配套的账本层**(手册之外,结构化、可被未来的 PendingCrew 项目驾驶舱渲染):
- [`docs/tech-debt.md`](../tech-debt.md) — 结构风险登记册(**计划**重构成一债一文件 + frontmatter)
- `docs/decisions.md` — 内容升华并入各 `concepts`,不再单列
- `docs/progress.md` — 编年 rollup,保持单文件
