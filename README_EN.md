<p align="center">
  <img src="docs/app-icon.png" width="128" alt="PendingBot app icon" />
</p>
<h1 align="center">PendingBot · 大绿豆</h1>

<p align="center">
  Honest with each other. Curious together. Proactive, candid, a VC for ideas.
</p>

<p align="center">
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/license-MIT-blue" /></a>
  <img alt="Swift" src="https://img.shields.io/badge/lang-Swift-F05138?logo=swift&logoColor=white" />
  <img alt="Platform" src="https://img.shields.io/badge/platform-iOS%20%C2%B7%20iPadOS%20%C2%B7%20macOS-lightgrey" />
  <img alt="Scope" src="https://img.shields.io/badge/repo-client%20only-lightgrey" />
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
> Not launched yet. Some features do not work.
>
> **This repository contains the client only** — the backend is not open source and is not here.
> You can build the app; it has no backend to talk to.
>
> The app UI and the documentation are in Chinese. This file is the only English translation;
> it tracks [`README.md`](README.md), which is the original.

## Quick start

**Just want to use it**

- **macOS** — grab the `.dmg` from [Releases](../../releases)
- **iPhone / iPad** — TestFlight: <https://testflight.apple.com/join/K6Ju9qqP>

⚠️ Both of those builds talk to **the author's own backend**. The one you build yourself does not —
see Configuration below.

**Want to build it yourself**

```bash
cd apps/pendingbot
xcodegen                                          # only after editing project.yml
xcodebuild -project PendingBot.xcodeproj -scheme PendingBot \
  -destination 'generic/platform=iOS Simulator' build
```

No Node / Bun / Docker needed — those are the backend's toolchain and the backend is not in this
repository. Full steps in [`docs/building.md`](docs/building.md).

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

The product is four parts on one main path. **This repository is only the leftmost box.**

```
  iOS / iPadOS / macOS          Cloudflare Worker              Supabase
  ┌──────────────────┐          ┌──────────────────┐          ┌──────────────┐
  │  SwiftUI client   │  HTTPS   │  Hono routes      │ Postgres │  80 tables    │
  │                  │ ───────► │  186 endpoints    │ ───────► │  130 RLS      │
  │  local cache      │ ◄─────── │  10 DOs           │ ◄─────── │  212 migr.    │
  └──────────────────┘  Realtime└──────────────────┘          └──────────────┘
     ▲                                  │
     │                                  ▼
     └── this repo is this box   ┌──────────────────┐
                                │  AI Gateway       │
         everything to the      │  4 providers →    │
         right is closed source │  1 exit, 20 tools │
         and not here           └──────────────────┘
```

- **Client** (`apps/pendingbot`) — one SwiftUI source tree builds all three platforms; the Xcode
  project is generated by xcodegen. Backend coordinates live in `HostedConfig.swift`, and the
  `isConfigured` value there is the single source of truth for "which paths are wired up".
  **This is the entire contents of this repository.**
- **Edge · database · admin console · AI Gateway** — a Cloudflare Worker on Hono, Supabase Postgres
  with RLS, a Refine admin console, and one unified model exit. **None of them are here.** The
  numbers above are measured from the author's deployment; they are printed so you know the shape of
  the thing the client talks to — not so you can rebuild it.

Why the `apps/pendingbot/` path is kept rather than hoisting the client to the repository root: it
**tells the truth**. This is one app inside a monorepo, with others beside it that are not open
source. Hoisting it would make it look like a standalone repository, which would be a pose.

**Where to find the wire shapes**: the types and comments under `Sources/Networking/` were written
against the Worker's routes and still carry references like `apps/edge/src/routes/…`. Those files
are not here, but the comments remain the most accurate record of what each endpoint takes and
returns.

## Status: how far does it actually go

> Surveyed **2026-08-19**, from read-only production queries plus a pass over the code — not from
> older conclusions sitting in documentation.

**First, the premise — and the premise has changed**: every capability below **depends on a backend
you do not have**. This repository is the client only; the Worker, the database and the model exit
are not here and are not open source. So this section reads as a **product inventory** rather than
"what you can run" — it records how far the author's deployment actually got. It is written down
plainly because a client-only repository makes it easier to overestimate what is behind it.

On the client side the single source of truth is `isConfigured` / `isEmailSignInConfigured` in
`apps/pendingbot/Sources/Networking/HostedConfig.swift`: they compare the coordinate constants in
the repository against the literals in `Placeholder`, and return `false` while the coordinates are
unfilled. This README deliberately does not maintain a second capability list, because two lists
will always drift apart.

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

### ② Backend-side code exists, but it needs extra credentials or external services

**This entire tier lives in the backend, which means this entire tier is not in this repository.**
It is kept because it explains why installing the app does not make anything come alive:

- **LLM conversation** (hard requirement) — Langfuse is the only source of prompt text, and **no
  repository holds a copy**. When the cache is empty and Langfuse has no matching prompt, the
  conversation path returns a 500. `LANGFUSE_ENABLED=false` only disables tracing; it does not
  bypass prompt loading.
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
- **Automated test coverage on the three client platforms is thin** — `apps/pendingbot/Tests/`
  holds three standalone suites (58 assertions) covering three Foundation-only modules. There is no
  `xcodebuild test` target yet, no UI tests and no real networking tests. This repository's CI runs
  exactly that: an iOS Simulator build plus those three suites. (The 695 tests live in the backend,
  which is not public.)

### Not there yet

- **A roadmap for PendingBot itself.** The existing one describes a different project that has since
  been split out.

(The screenshots above were taken from the author's own machine, so the interface is real; but the
conversations, bots and "letters" in them are local data and do not imply the same output ever
existed in production — for the real production scale, see the top of this section.)

## Running it

Full steps in [`docs/building.md`](docs/building.md). The essentials:

- `cd apps/pendingbot`, and run `xcodegen` if you have edited `project.yml` (`PendingBot.xcodeproj`
  is committed, so a fresh clone opens straight away).
- Building for the Simulator with `xcodebuild` needs no signing. Installing on **your own device**
  means switching to **your own Signing Team** in Xcode — the one in the repository is the author's.
- The app you build **has no backend to talk to**. That is not a missing configuration step; it is
  the boundary of this repository.

No Bun / Node / Docker / Supabase CLI needed. Those are the backend's toolchain and the backend is
not in this repository.

## Configuration

> This section is load-bearing on the Chinese side. The in-app notice quoted under Quick start is
> compiled into the binary and points at **「配置」 in [`README.md`](README.md#配置)** by name — that
> heading cannot be renamed without shipping a new build. This English section is the mirror of it;
> renaming *this* one is harmless, but keep the pair in sync.

All backend coordinates for the app live in `HostedConfig.swift`; edit the constants under the
`Environment.remote` branch. **Do not touch the literals in `Placeholder`** — they are what the two
predicates above compare against. Change them and the predicates become permanently true, and the
app falls back to failing silently.

While the predicates are `false`, **nothing is raised at launch** — someone running only a local
stack never touches the hosted constants, and warning them about something they cannot act on is a
false alarm. The predicates are read once, at the moment an entry point is actually pressed: tap
Apple / Google / email sign-in and it says, in place:

> 本仓库只带占位后端坐标，登录走不通。要接自己的 Cloudflare Worker + Supabase，见 README 的「配置」一节。
>
> *("This repository ships placeholder backend coordinates, so sign-in cannot work. To connect your
> own Cloudflare Worker + Supabase, see the Configuration section of the README.")*

All three entry points (Apple / Google / email code) share that one line; no spinner, no silent
failure. Measured by actually tapping all three on a build with unfilled coordinates — it is not a
statement of intent.

The `.dev` branch points at `localhost:8787` and `localhost:54321`, which the predicates treat as
configured. It exists for "a backend running on this machine" — and that backend is not in this
repository, so for an outside reader it amounts to "point it at your own". There is no runtime
switch yet; switching means editing that one default.

Google sign-in has one more spot: `GIDClientID` and the reversed URL scheme in both `Info.plist`
files are placeholders too.

The Universal Links / AASA domain, the Associated Domains entitlement and the share-link domain in
the code are still the author's. Changing to your own domain means changing all three.

## Downloads

**Releases contain the macOS build (`.dmg`) only. The iOS build is not there, and cannot be.**

Apple does not permit distributing iOS apps outside the App Store and TestFlight — there is no
"download a package and install it" route. To run it on an iPhone you have two options: install it
from Xcode onto your own device with your own developer account, or wait for the author to actually
ship it to the App Store (no timeline for that).

The macOS build uses signed and notarized direct distribution, so downloading and opening it is
enough.

## Repository layout

```
apps/
└── pendingbot/       Native SwiftUI app (iOS / iPad / macOS, xcodegen-based)
                      — the entire contents of this repository
scripts/
└── release/
    └── stamp-build-info.sh   Writes "which commit was this built from" into the product's
                              Info.plist at the end of a build. Invoked by a build phase in
                              project.yml — part of building, not a release script.
docs/                 building.md plus the images the README uses
```

Only one directory is left under `apps/`, but that path level is kept **on purpose**: it says out
loud that this is one app inside a monorepo, with others beside it that are not open source.

**Not here**: the Cloudflare Worker backend, the Supabase migrations and RLS, the admin console, the
group-voice media container, the auth middleware, the packaging and notarization scripts, and all of
the internal ledgers (progress / tech debt / decision log). These are not "not tidied up yet" —
they are **not open source**.

Separately, **PendingCrew** (the macOS agent-orchestration app) lives in its own repository. Code comments occasionally reference internal design documents such as
`docs/superpowers/plans/…` — those were not published, so a dangling reference is not a missing file.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). In short: this is a personal experiment. Issues and pull
requests are welcome, but the author promises neither response times nor a roadmap.

For security issues, please use the private reporting channel in [`SECURITY.md`](SECURITY.md) rather
than opening a public issue.

## License

[MIT](LICENSE).

Third party: the client's SPM dependencies (GRDB · GoogleSignIn · MarkdownUI · PostHog · RevenueCat ·
Sentry · SwiftMath · supabase-swift · WebRTC) are each under their own license; the exact versions
and sources are in [`apps/pendingbot/project.yml`](apps/pendingbot/project.yml).

---

<sub>The positioning, features and goals were written by the author. The technical sections
(architecture, status survey, building and configuration) were written by Claude, and every
number and conclusion in them comes from a command that was actually run or a read-only production
query — not copied from older documents. This English file is a translation of
<a href="README.md">README.md</a>; if the two disagree, the Chinese original wins.</sub>
