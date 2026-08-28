<p align="center">
  <img src="docs/app-icon.png" width="128" alt="PendingBot app icon" />
</p>
<h1 align="center">PendingBot · 大绿豆</h1>

<p align="center">
  Honest with each other. Curious together. Proactive, candid, a VC for ideas.
  <br />
  <em>No dodging, no hiding, no detours, no hype. It holds you steady — and it opens you up</em>
</p>
<p align="center">
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/license-MIT-blue" /></a>
  <img alt="Runtime" src="https://img.shields.io/badge/runtime-Cloudflare%20Workers-f38020?logo=cloudflare&logoColor=white" />
  <img alt="TypeScript" src="https://img.shields.io/badge/lang-TypeScript-3178c6?logo=typescript&logoColor=white" />
  <img alt="Swift" src="https://img.shields.io/badge/lang-Swift-F05138?logo=swift&logoColor=white" />
  <img alt="Platform" src="https://img.shields.io/badge/platform-iOS%20%C2%B7%20iPadOS%20%C2%B7%20macOS-lightgrey" />
</p>


<p align="center">
  <a href="README.md">中文</a> · <a href="README_EN.md">English</a>
</p>

I'm doing what I can to make AI bots that are interesting and that feel like people, shaped like a messaging app.

<p align="center">
  <img src="docs/screenshots/main.png" width="820" alt="Main window: conversation list on the left, a chat with a bot on the right" />
</p>

> Not officially launched yet. Some features don't work.

## Quick start

- **macOS** ——  [Releases](../../releases)
- **iPhone / iPad** —— [TestFlight](https://testflight.apple.com/join/K6Ju9qqP)

## Documentation I wrote with care

<https://docs.pendingname.com/pendingbot>



<table>
<tr>
<td width="50%"><img src="docs/screenshots/contacts.png" alt="Contacts: three private bots, each on a different model" /></td>
<td width="50%"><img src="docs/screenshots/letter.png" alt="Letters: a letter a bot wrote on its own initiative" /></td>
</tr>
<tr>
<td><b>Contacts</b><br>Fairly self-explanatory: bot friends and human friends, together forming a social graph</td>
<td><b>Letters</b><br>Writing and receiving letters inside a messaging app has a flavor of its own<br><sub>functionally the same as email, but it doesn't taste the same</sub></td>
</tr>
</table>

## What it's for

This app isn't here to solve any particular use case. Call it a piece of humanities work — mostly it's research into how to make these bots feel more like people, and how to make them something you can interact with directly, without reading any documentation. The way a three-year-old knows how to use an iPhone.

In terms of what they do, what I want from the bots inside is:

- **Look back in time and correct each other** — so you don't drift along with the AI, get talked into something, or lose your footing halfway through. The player is lost in the game; the onlooker sees it clearly.
- **Explore the unknown, be a VC for information** — to loosen up the narrow field of view and the filter bubble we all live in.

Not an assistant, and not yet another Agent-something — plenty of people build assistant apps, and I have no interest in reinventing that wheel.

Not standard AI companionship either — it isn't an obedient baby. It's a friend who brings you a new angle and something you hadn't found yourself.

## Architecture

### The whole system

The product is four boxes and one main path. **This repository is only the leftmost box.**

```
     this repository             ✗ nothing below is in this repository, and none of it is open source
 ┌────────────────────┐          ┌──────────────────────┐          ┌────────────────────────┐
 │  SwiftUI client    │  write → │  Cloudflare Worker   │    →     │  Supabase              │
 │  iOS/iPadOS/macOS  │          │  Hono · 186 endpoints│          │  Postgres              │
 │                    │  ← read  │  10 Durable Objects  │    ←     │  80 tables · RLS on all│
 │  GRDB local cache  │          │  2 containers        │          │  215 migrations        │
 └────────────────────┘          └──────────────────────┘          └────────────────────────┘
           ▲                                 │
           └────── realtime WebSocket ───────┤
                                             ▼
                                 ┌──────────────────────┐
                                 │  AI Gateway          │
                                 │  4 providers → 1 exit│
                                 └──────────────────────┘
```

- **Client** (`apps/pendingbot`) — one SwiftUI source tree builds all three platforms. **This is the
  entire contents of this repository.**
- **Edge** — a single Cloudflare Worker, routed with Hono. The stateful parts go to Durable Objects:
  realtime broadcast, read projections, group-chat routing, voice rooms, wallet, cross-device remote
  control. The code sandbox and the group-voice media each run in their own container.
- **Database** — Supabase Postgres, RLS on every table. Row changes go back out to the edge through a
  webhook for realtime fan-out.
- **Model exit** — one AI Gateway collapses four providers into a single exit. Deliberately **not
  using the gateway's compatibility translation layer** — that layer strips Anthropic's extended
  thinking and Gemini's search grounding.

Those numbers are the measured size of my own deployment. They're here so you know **what shape of
thing the client is talking to**, not so you go and build one like it.

**One message's round trip**, which strings the four boxes together:

```
you hit send
  → the client optimistically inserts a local bubble first (GRDB)
  → POST /v1/messages to the Worker; the HTTP connection stays open and switches to SSE coming back
  → the Worker assembles the prompt → AI Gateway → provider
  → tokens stream back one by one, the client renders as they arrive
  → the Worker writes the final message into Postgres
  → database webhook → edge broadcast → your other devices get the same message over WebSocket
```

The same message **goes out over HTTP, grows over SSE, and syncs elsewhere over WebSocket**. Three
channels, each with its own job — which is the prerequisite for understanding why the client's
network layer looks the way it does below.

### The client

**One target builds three platforms**, 178 Swift files, roughly 47.6k lines.

`project.yml` has exactly one application target, `supportedDestinations: [iOS, macOS]`. Platform
differences are **not handled by splitting targets**, but by three things:

- the whole `Sources/Mac/` subtree is excluded from the iOS build — right now it's down to **one
  file** (the Mac sign-in screen), everything else is shared by both platforms;
- iOS-only files wrap a `#if os(iOS)` around the top, so the pure Foundation / SwiftUI model,
  storage and network layers **fall into the Mac build naturally**, with no second copy written for
  the Mac;
- dependencies only iOS needs (WebRTC) are marked `platforms: [iOS]` in `project.yml`.

**Two shells, the same set of features.** Screen width decides how things are assembled, not whether
two versions of the UI get written:

```
compact (iPhone)              bottom TabView, each tab self-contained with its own push stack
wide (iPad landscape / Mac)   NavigationSplitView, three columns: tab sidebar │ list │ detail
```

What glues the two together is a protocol, `FeatureSurface`: every feature hands over three pieces of
assembly — `listColumn` / `detailColumn` / `compactRoot` — and the shell puts them together itself.
All five tabs (Messages / Friends / Crew / Letters / Me) go down the same path, and macOS's `@main`
and the iPad wide layout **share the same shell**, with no parallel implementation.

**Reads and writes don't take the same route — this is the first thing to know about the client.**

- **Writes** — all go through `APIClient` to the Worker (sending messages, uploads, group
  management…). The client has **no** matching GET side.
- **Reads** — a three-step ladder; if one step doesn't work, fall to the next:

  ```
  L1  GRDB local cache        on screen immediately, something to look at even offline
  L2  edge read projection    GET /v1/conversations, /v1/messages/tail
  L3  Supabase direct read    if any level above errors out, or comes back suspiciously empty,
                              fall back to here
  ```

  L2 carries scalar columns only; nested fields like avatars and names are filled in on the spot by
  L1 — redundantly baking them into the projection would mean a full fan-out every time a bot renames
  itself. If they can't be filled in, they stay empty and get filled on the next refresh.

- **Realtime** — two layers of WebSocket, connected to the edge's broadcast Durable Object, **not** to
  Supabase Realtime channels: one user-level connection stays open (unread counts, letters), and
  conversation-level ones open and close on demand (messages, group votes, membership changes).

**Local storage is encrypted.** GRDB links against a SQLCipher build; the database is `PRAGMA key`'d
with a random 256-bit key, and that key lives in the keychain and is not synced to iCloud. Cached
attachment images carry file-protection attributes. The whole database is wiped on sign-out.

**The client carries a gate of its own.** `SupabaseAnonWriteGuard`: when supabase-swift can't get a
session, it will **send the write out anyway, as an anonymous identity**; the server answers
"permission denied", and the trail ends right there — this shape got misdiagnosed as a backend bug
twice. This gate makes the request fail before the bytes ever leave the device, and reports the real
reason. It's a mechanism, not a convention.

**Where to find the shapes of the endpoints**: the types and comments in `Sources/Networking/` were
written against the Worker's routes, and still carry references like `apps/edge/src/routes/…`. Those
files aren't here, but the comments are still the most accurate record of "what this endpoint takes
and what it gives back".

**The backend coordinates live in exactly one place**: `HostedConfig.swift`. The `isConfigured` in it
is the single source of truth for "which paths are wired up".

### Repository layout

```
apps/pendingbot/          the client, the substance of this repository
  project.yml             XcodeGen definition (the one and only target lives here)
  Sources/
    Features/       80    screens and view models grouped by feature, the biggest chunk
    Networking/     36    network, realtime, auth, cache repositories, backend coordinates
    Components/     35    reusable UI atoms: avatars, bubble layout, Markdown/formulas, QR, theming
    Storage/         9    local database, keychain, account state, unread counts, model catalog
    Models/          9    value types shared across layers
    Mac/             1    Mac-only UI (the sign-in screen), excluded wholesale from the iOS build
    Stores/          1    shared state across features
  Tests/                  unit tests
  Resources/              Info.plist, asset catalogs

docs/                     screenshots, icons, reader-facing documentation
scripts/                  repository self-check scripts (link checking and so on)
.github/workflows/        CI: client build, documentation links
```

**What is not in this repository**: the Cloudflare Worker, the Supabase migrations and RLS, the admin
console, the deployment scripts. Every backend coordinate in the client is a placeholder value —
**an app built from this repository runs, but it connects to no backend at all**. Tapping sign-in
tells you right there that nothing is configured, rather than failing silently.

## License

[MIT](LICENSE)

Third party:
- The Agent Skills presets are vendored from [anthropics/skills](https://github.com/anthropics/skills)
  (Apache-2.0); see [`apps/edge/prompts/skills/anthropic/NOTICE.md`](apps/edge/prompts/skills/anthropic/NOTICE.md)
  and the `LICENSE.txt` in the same directory.
- Runtimes / libraries: Cloudflare Workers · Hono · Supabase · Bun · Zod and others, each under its
  own license.
