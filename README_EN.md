<p align="center">
  <img src="docs/app-icon.png" width="128" alt="PendingBot app icon" />
</p>
<h1 align="center">PendingBot · 大绿豆</h1>

<p align="center">
  Honest with each other. Curious together. Proactive, candid, a VC for ideas.
</p>

<p align="center">
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/license-MIT-blue" /></a>
  <a href="https://bun.sh"><img alt="Bun" src="https://img.shields.io/badge/runtime-Bun-fbf0df?logo=bun&logoColor=black" /></a>
  <img alt="TypeScript" src="https://img.shields.io/badge/lang-TypeScript-3178c6?logo=typescript&logoColor=white" />
  <img alt="Swift" src="https://img.shields.io/badge/lang-Swift-F05138?logo=swift&logoColor=white" />
  <img alt="Platform" src="https://img.shields.io/badge/platform-iOS%20%C2%B7%20iPadOS%20%C2%B7%20macOS-lightgrey" />
</p>

<p align="center">
  <a href="README.md">中文</a> · <a href="README_EN.md">English</a>
</p>

An AI that knows when it got something wrong. It goes out and reads the web on its own, and it does that with you in mind. Shaped like a messaging app.

<p align="center">
  <img src="docs/screenshots/main.png" width="820" alt="Main window: conversation list on the left, a chat with a bot on the right" />
</p>

> **This is one person's experiment, not a product.**
>
> Nothing is operated for you, there are no real users, and there is no support commitment.
> The [Status](#status-how-far-does-it-actually-go) section below spells out which features have
> genuinely run and which are only code sitting there. Accept one thing before you read on:
> **clone it and out of the box you can do nothing** — you have to connect your own backend first.
>
> The app UI and the documentation are in Chinese. This file is the only English translation;
> it tracks [`README.md`](README.md), which is the original.

## Quick start

**Just want to use it**

- **macOS** — grab the `.dmg` from [Releases](../../releases). It is signed and notarized by Apple, so it installs on a double-click.
- **iPhone / iPad** — TestFlight only: <https://testflight.apple.com/join/K6Ju9qqP>

⚠️ **Installing it is not enough — you still have to connect your own backend before you can actually talk to anything.**
This repository ships no real backend coordinates. Tapping sign-in tells you plainly that nothing is
configured, rather than failing silently. See [`docs/self-hosting.md`](docs/self-hosting.md).

**Want to run the code yourself**

```bash
bun install                                      # bun 1.3.11+
bun --filter='@pendingbot/edge' run typecheck    # expect 0 errors
cd apps/edge && ./node_modules/.bin/vitest run   # 695 tests
```

## Documentation

<https://docs.pendingname.com> (Chinese)

## What it does

- Keep revisiting and fact-checking the conversation between you and the AI — not only so it can catch its own mistakes, but so it can push back on yours, surface the blind spots in your own thinking, and let both sides keep getting better.
- Dig through the internet on its own initiative, hunting for things that are worth your attention and that make you look twice.
- Do all of the above **on its own schedule** — not only when you ask, not one answer per question.

<table>
<tr>
<td width="50%"><img src="docs/screenshots/contacts.png" alt="Contacts: three private bots, each on a different model" /></td>
<td width="50%"><img src="docs/screenshots/letter.png" alt="Letters: a letter the bot wrote on its own initiative" /></td>
</tr>
<tr>
<td><b>Contacts</b><br>Your contact list is full of bots, and <b>each one can run on a different model</b>.</td>
<td><b>Letters</b><br>The bot writes you a letter instead of a message — what it wants to say does not always belong in a chat bubble.<br><sub>⚠️ UI demo. On the author's production database this path has <b>never produced a single letter</b>. See Status below.</sub></td>
</tr>
</table>

## Two goals

- **Look back in time, and correct each other** — so you don't drift with the AI, get talked into something, or lose your footing halfway through a conversation. The player is lost in the game; the onlooker sees it clearly.
- **Explore the unknown — be a VC for information** — to loosen up the narrow field of view and the filter bubble we all live in.

Not an assistant. Not yet another Agent-something — plenty of people build assistant apps, and I have no interest in reinventing that wheel.

Not standard AI companionship either — it is not an obedient baby. It is a friend who brings you a new angle and something you had not found yourself.

## Architecture

Four parts, one main path.

```
  iOS / iPadOS / macOS          Cloudflare Worker              Supabase
  ┌──────────────────┐          ┌──────────────────┐          ┌──────────────┐
  │  SwiftUI client   │  HTTPS   │  Hono routes      │ Postgres │  80 tables    │
  │                  │ ───────► │  186 endpoints    │ ───────► │  130 RLS      │
  │  local cache      │ ◄─────── │  10 DOs           │ ◄─────── │  212 migr.    │
  └──────────────────┘  Realtime└──────────────────┘          └──────────────┘
                                        │
                                        ▼
                                ┌──────────────────┐
                                │  AI Gateway       │
                                │  4 providers →    │
                                │  1 exit, 20 tools │
                                └──────────────────┘
```

- **Client** (`apps/pendingbot`) — one SwiftUI source tree builds all three platforms; the Xcode
  project is generated by xcodegen. Backend coordinates live in `HostedConfig.swift`, and the
  `isConfigured` value there is the single source of truth for "which paths are wired up".
- **Edge** (`apps/edge`) — Cloudflare Worker + Hono, the bulk of the product. Durable Objects hold
  the stateful pieces (conversation turns, rate limiting, realtime projections). All 695 tests live
  in this layer.
- **Database** (`supabase/`) — Postgres + RLS. Every cross-user read and write is backstopped by
  RLS, and a CI gate watches `SECURITY DEFINER` functions so their privileges cannot drift back to
  PUBLIC.
- **Admin console** (`apps/admin`) — a Refine SPA, bundled as static assets inside the Worker,
  behind Cloudflare Access.

**Two external dependencies deserve their own note:**

- **Langfuse is the single source of truth for prompts; there is no copy in this repository.** That
  is deliberate — it avoids one version in code and another in production, which will disagree
  sooner or later. The cost is that self-hosting requires you to create all 18 prompts in Langfuse
  verbatim first, or the conversation path returns a 500.
- **Four LLM providers are unified behind one AI Gateway exit**, with 20 tools available to the
  model. Switching providers does not touch business code.

## Status: how far does it actually go

> Surveyed **2026-08-19**, from read-only production queries plus a pass over the code — not from
> older conclusions sitting in documentation.

**First, the premise**: this public repository carries no real backend coordinates.
`isConfigured` / `isEmailSignInConfigured` in
`apps/pendingbot/Sources/Networking/HostedConfig.swift` are the **single source of truth** for what
is wired up and what is not — this README deliberately does not maintain a second capability list,
because two lists will always drift apart. With the coordinates unfilled they return `false`, and
tapping sign-in tells you so instead of failing silently.

| Predicate | Constants compared | Governs |
|---|---|---|
| `isConfigured` | `workerURL`, `supabaseURL`, `supabasePublishableKey` | The whole hosted path: sign-in, chat, contacts |
| `isEmailSignInConfigured` | the three above + `turnstileSiteKey`, `turnstileHost` | Only the email one-time-code route |

On top of that, features fall into three tiers.

### ① Genuinely exercised (with production data on the author's deployment to back it up)

Production Worker healthy · **1-on-1 text chat on iPhone** · both LLM paths (OpenRouter and native
Anthropic pass-through each have successful calls on record) · automatic conversation titling ·
edge read projection for the conversation list · all three sign-in methods (Apple / Google / email
code) · admin console behind Cloudflare Access · Universal Link AASA · prompt distribution · memory
read and write · device authorization / family SSO · one real top-up · the macOS build (author's own
daily use — a live platform, not a placeholder)

**The scale of this tier needs saying plainly**: production holds **142 messages in total, all of
them** in 1-on-1 `user_bot` conversations. "Genuinely exercised" means the author has used it — not
that it has been tested by real-world use.

### ② The code is there, but it needs extra credentials or external services

Once your own backend is connected, these still need their own keys:

- **LLM conversation** (hard requirement) — Langfuse is the only source of prompt text, and **there
  is no copy in the repository**. On a fresh deployment the cache is empty, and if Langfuse has no
  matching prompt the conversation path returns a 500. `LANGFUSE_ENABLED=false` only disables
  tracing; it does not bypass prompt loading. Self-hosting means creating all 18 prompts in Langfuse
  verbatim first — section 6 of [`docs/self-hosting.md`](docs/self-hosting.md) lists their names.
- **Realtime push** — requires `realtime_webhook_url` and `realtime_webhook_secret` in Supabase
  Vault, with the same secret configured in the Worker. Without it there is simply no push;
  everything else is unaffected.
- **Billing / top-ups** — Polar (the wallet itself) and RevenueCat (iOS) both need your own accounts
  and webhooks.
- **Voice** — Cloudflare RealtimeKit plus OpenAI Realtime; you need credentials for both.
- **Attachment upload** — you have to create an R2 bucket and bind it.
- **Telemetry** — Sentry / PostHog / Langfuse keys are disabled when left empty; omitting them is
  not an error.

### ③ Written, but never wired up / zero production data

The following are **0 rows on the author's production database**: the code path exists, but there is
no evidence any of it has ever run end to end. Do not expect "install it and it works".

Bot replies in group chats · voice (1-on-1 and group; never once connected in production) ·
attachment upload · **proactive lookback** (`bot_lookbacks` is 0 rows — the core of the product has
never produced a single one) · bot and group invites · adding friends · push notifications ·
model blind box · skill subscriptions · code sandbox · in-app-purchase top-ups · group-account wallets

A few more, stated precisely:

- **"Surfing the web" necessarily fails in production** — the only search-and-fetch channel is the
  Exa MCP, whose API key has never been deployed, so the call throws outright. (To distinguish:
  **looking something up mid-conversation** does not go through this path; it uses each model
  vendor's own server-side tools, and that half may well work.)
- **Short links / remote-control index** — the tables exist in production, the repository has no
  code for them (lost along with a commit-loss incident).
- **Zero automated tests on the three client platforms** — there are no CI tests on the Swift side;
  all 695 tests are in the Edge layer (`apps/edge`).

### Not there yet

- **A roadmap for PendingBot itself.** The existing one describes a different project that has since
  been split out.

(The screenshots above were taken from the author's own machine, so the interface is real; but the
conversations, bots and "letters" in them are local data and do not imply the same output ever
existed in production — for the real production scale, see the top of this section.)

## Running it

The full walkthrough — including which external service to open and what to take from each — is in
[`docs/self-hosting.md`](docs/self-hosting.md). That guide was checked against a real run on a clean
checkout, including which steps **did not** work.

The shortest path is the three commands under Quick start. Per component:

- **Edge (backend)** — build the admin assets first with
  `bun --filter='@pendingbot/admin' run build`, then `cd apps/edge && wrangler dev --local`. Running
  it bare only proves the Worker starts; the business routes need a local Supabase.
- **Database** — `supabase start` plus `supabase db reset --local`. All migrations and both seeds
  have been run through on an offline Docker network.
- **App** — `cd apps/pendingbot && xcodegen` (the repository ships no committed scheme, so **a fresh
  clone must run this first**), then open `PendingBot.xcodeproj` in Xcode, pick your own Signing
  Team, and build.

## Configuration

All backend coordinates for the app live in `HostedConfig.swift`; edit the constants under the
`Environment.remote` branch. **Do not touch the literals in `Placeholder`** — they are what the two
predicates above compare against. Change them and the predicates become permanently true, and the
app falls back to failing silently.

To run purely locally, change the default of `HostedConfig.environment` from `.remote` to `.dev`
(the coordinates point at localhost, which the predicates treat as configured). There is no runtime
switch yet.

Google sign-in has one more spot: `GIDClientID` and the reversed URL scheme in both `Info.plist`
files are placeholders too.

The Edge-side variables, bindings and secrets are listed in [`.env.example`](.env.example) and
`apps/edge/wrangler.jsonc` — in the latter, every value shaped like `YOUR_…` or `example.com` is a
placeholder.

## Downloads

**Releases contain the macOS build (`.dmg`) only. The iOS build is not there, and cannot be.**

Apple does not permit distributing iOS apps outside the App Store and TestFlight — there is no
"download a package and install it" route. To run it on an iPhone you have two options: install it
from Xcode onto your own device with your own developer account, or wait for the author to actually
ship it to the App Store (no timeline for that).

The macOS build uses signed and notarized direct distribution, so downloading and opening it is
enough.

## Repository layout

A single bun-workspaces repo.

```
apps/
├── edge/             Cloudflare Worker + Hono + Supabase + R2 — the backend proper
├── pendingbot/       Native SwiftUI app (iOS / iPad / macOS, xcodegen-based)
├── admin/            Refine SPA admin console (bundled as static assets into the edge worker)
└── voice-container/  Group-voice media container (CF Container + Bun)
packages/
└── identity/         Supabase JWT + auth middleware
supabase/             migrations / seeds / config
scripts/              schema-regen check, Supabase advisor gate, SECURITY DEFINER gate, release scripts
docs/                 self-hosting guide only; the internal ledgers (progress / tech debt / decision
                      log) are not part of this public repository
```

**PendingCrew** (the macOS agent-orchestration app) was split out at the same time and now lives in
its own repository. Code comments occasionally reference internal design documents such as
`docs/superpowers/plans/…` — those were not published, so a dangling reference is not a missing file.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). In short: this is a personal experiment. Issues and pull
requests are welcome, but the author promises neither response times nor a roadmap.

For security issues, please use the private reporting channel in [`SECURITY.md`](SECURITY.md) rather
than opening a public issue.

## License

[MIT](LICENSE).

Third party:
- The Agent Skills presets are vendored from [anthropics/skills](https://github.com/anthropics/skills)
  (Apache-2.0); see [`apps/edge/prompts/skills/anthropic/NOTICE.md`](apps/edge/prompts/skills/anthropic/NOTICE.md)
  and the `LICENSE.txt` beside it.
- Runtimes and libraries: Cloudflare Workers · Hono · Supabase · Bun · Zod and others, each under
  its own license.

---

<sub>The positioning, features and goals were written by the author. The technical sections
(architecture, status survey, self-hosting and configuration) were written by Claude, and every
number and conclusion in them comes from a command that was actually run or a read-only production
query — not copied from older documents. This English file is a translation of
<a href="README.md">README.md</a>; if the two disagree, the Chinese original wins.</sub>
