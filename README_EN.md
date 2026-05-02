<p align="center">
  <img src="docs/app-icon.png" width="128" alt="PendingBot app icon" />
</p>
<h1 align="center">PendingBot</h1>

<p align="center">
  Honest with each other. Curious together. Proactive, candid, a VC for ideas.
  <br />
</p>
<p align="center">
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/github/license/syncmeta/PendingBot?color=blue" /></a>
  <a href="https://bun.sh"><img alt="Bun" src="https://img.shields.io/badge/runtime-Bun-fbf0df?logo=bun&logoColor=black" /></a>
  <img alt="TypeScript" src="https://img.shields.io/badge/lang-TypeScript-3178c6?logo=typescript&logoColor=white" />
  <img alt="Platform" src="https://img.shields.io/badge/platform-Web%20%7C%20iOS-lightgrey" />
</p>


An AI that catches its own mistakes and scouts the world for you while you sleep.

## What it does:

- Goes back over your conversations with the AI again and again — not just to call out its own slip-ups, but to push back on you, too: to point out where your thinking's off, where you've got blind spots, where you've been wrong. So both of you actually grow.
- Digs deep across the internet, hunts around on its own, scours every corner for stuff that's actually useful to you — the kind of thing that makes you go "oh, this is good."
- Does all of the above without being told — it speaks first, it doesn't just talk when spoken to.

## Aim:

- **Keep each other honest** — so you don't drift, get fooled, or lose the plot mid-conversation with an AI.
- **Be a VC for ideas** — scouting what's beyond your current bubble. Extend your mind, without losing it.

**Not** an assistant, **not** a world's first ___ agent — plenty of those already!

**Not** your typical AI companion either — not a yes-man, not a therapist-in-a-box, not someone who'll tell you you're brilliant when you're not.

More like a friend who brings a new perspective. That's what good friends actually do.

The content below is, for now, written by Claude. I'll check it later.

## ✨ What it can actually do

It revolves around three things — chat, reflection, exploration — and you don't have to nudge it. It does these on its own.

- **🧠 Proactive chat** — WeChat-style by default: short turns, pauses, no over-explaining; switchable to a standard AI tone. If you're typing fast mid-thought, it pauses instead of barreling over you.
- **🪞 Self-review / keeping each other honest** — every N rounds it goes back over the recent conversation: was something it said muddled? Where do you have blind spots? Then it comes back and tells you.
- **🌊 Web surfing** — it goes off and scrounges around the internet for things actually worth showing you, and brings the best bits back to the conversation. Trigger manually with `/surf`, or let it run on a schedule.
- **🗣️ A circle of bots talking about you** — pull the bots you regularly chat with into a group, and let them discuss *you* — like a circle of friends talking about you behind your back. Multi-angle outside perspective.
- **🪪 Long-term portrait & memory** — backed by [Honcho](https://honcho.dev): it builds a picture of you over time and remembers things, which feeds back into how it chats, reflects, and surfs.
- **👥 Many-to-many social / information network** — one bot can chat with many people, and one person can chat with many bots, weaving humans and bots into a network. Friends can co-raise the same bot, which then carries an impression of each of you.
- **🤖 Basic agent capabilities** — Anthropic-style markdown skills as a starting point; more mature agent capability is on the way.
- **🔐 BYOK** — don't want to be billed by the host? Drop in your own OpenRouter key and every call runs on your account.

## 💬 What it's like to actually use

A few concrete moments:

- **It pulls the brake mid-chat**: you're hashing out a decision; a few rounds later it sends, "Hold on — what I said earlier contradicts itself, retracting."
- **You wake up to a surf haul**: `autoTrigger` was on overnight; it went off and rummaged for hours, and now there are three angles you hadn't considered.
- **Listening to your bots talk about you**: the bots you usually chat with sit down together and discuss a decision you're stuck on, while you watch — multi-angle outsiders.
- **A few friends co-raising one bot**: a small friend group raises one bot together; it has an impression of each of you and can stitch the different perspectives together.
- **Heavy GPT/Claude/Grok user with your own key**: drop your OpenRouter key under "Me" → Settings; from then on every model call goes against your account.

## 🚀 Get started

The repo is mid-rewrite, moving from the old Bun + Fly backend to a Cloudflare Worker + Supabase one. **There is no public self-host path right now.** Only the iOS app is usable (still unreleased):

```bash
brew install xcodegen
cd apps/ios && xcodegen generate
open PendingBot.xcodeproj
```

Pick a Signing Team on first open. See [apps/ios/README.md](apps/ios/README.md).

## 📍 Progress

Concrete shell · rewrite in progress.

- **Backend (apps/edge)** — Cloudflare Worker + Hono + Supabase + R2; skeleton up.
- **iOS (apps/ios)** — core tabs working; sign-in via Apple / Google; not yet on the App Store.
- **Web (apps/web)** — placeholder, not started.

## 🙏 Credits & references

- **Portrait & memory**: [Honcho](https://honcho.dev) ([plastic-labs/honcho](https://github.com/plastic-labs/honcho), Apache-2.0).
- **Agent Skills presets** from [anthropic/skills](https://github.com/anthropics/skills) (Apache-2.0), vendored under [apps/edge/prompts/skills/anthropic/](apps/edge/prompts/skills/anthropic/) — see [NOTICE](apps/edge/prompts/skills/anthropic/NOTICE.md).
- **Runtime**: [Cloudflare Workers](https://workers.cloudflare.com) · [Hono](https://hono.dev) (MIT) · [Supabase](https://supabase.com) · [Bun](https://bun.sh) (MIT, toolchain) · [OpenAI SDK](https://github.com/openai/openai-node) (Apache-2.0) · [Zod](https://github.com/colinhacks/zod) (MIT).
- **External services**: [OpenRouter](https://openrouter.ai) (model routing) · [Honcho](https://honcho.dev) (portrait) · [Daytona](https://daytona.io) (sandbox) · APNS.

## 📂 Repo layout

```
PendingBot/                  bun workspaces monorepo
├── apps/
│   ├── edge/                CF Worker + Hono backend
│   ├── web/                 (placeholder)
│   └── ios/                 Native SwiftUI iOS app
├── packages/
│   ├── core/                Shared core logic
│   ├── identity/            Supabase JWT + auth middleware
│   └── shared-types/        Shared types
└── supabase/                migrations / config
```

> The brand site `pendingname.com` lives in another repo, `syncmeta/PendingName-web`.

## 🤝 Contributing

Issues and PRs welcome. A quick chat about the idea before submitting tends to go smoother, especially for prompt / surfing-pipeline / cross-platform-protocol changes.

## 📄 License

[MIT](LICENSE). Third-party components keep their original licenses (above).

---

<p align="center">
  Made with 💚 for people who want a friend that pushes back, not a tool that nods along.
</p>
