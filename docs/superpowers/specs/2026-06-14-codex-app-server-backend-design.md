# Codex app-server backend (PendingCrew) — design

**2026-06-14** · feeds the implementation plan. Supersedes the codex "placeholder terminal" in `SessionConfig.swift`.
Protocol facts live in `2026-06-05-codex-app-server-reference.md` (empirical, codex 0.137.0) — this doc is the *integration* design, not the protocol bible.

## North star

**Make codex run as if the user typed `codex` in the session's working directory — only the output is structured events instead of terminal bytes.**

Everything follows from that: same local `codex` login, same cwd, same default behavior. We spawn `codex app-server` (a local child process, stdio JSON-RPC) instead of attaching a PTY, so we can render a faithful structured transcript and route the (rare) approval requests through our existing approval UI.

claude stays on the SwiftTerm terminal (no app-server equivalent; interactive TUI is required for subscription billing). **Only codex moves.**

## What we do NOT manage

- **Credentials / login.** `codex app-server` shares the user's local codex auth exactly like the CLI. If `codex` works in that dir in a terminal, the app-server works the same. We pass no keys.
  - On connect we call `account/read`; if it returns an authenticated account → go. If a newer codex requires client-driven auth (`account/login/start`) and `account/read` shows unauthenticated, we surface "log into codex" and stop — we do not build a login flow in v1. (Auth model differs between our 0.137.0 probe = auto-reads `~/.codex/auth.json`, and current OpenAI docs = client-driven. Resolve by probing the installed version — see Real-machine tail.)
  - Footnote, not a red line: when building the child env, don't inject `OPENAI_API_KEY` (an exported API-key env var can flip subscription→pay-as-you-go). Our `LocalCodingAgentEnv` whitelist already omits it; just keep it omitted for codex.

## Architecture

```
CrewSessionRunner.start(config: kind == .codex)
  → SessionWorkspace.resolve(...)            # cwd (worktree or shared dir) — unchanged
  → LocalCodingAgentEnv.build(...)           # clean env — unchanged (no OPENAI_API_KEY)
  → CodexAppServerBackend(executable, cwd, env, config, providers...)
       ├─ CodexAppServerConnection (actor)   # spawn `codex app-server`, stdio JSON-RPC framing
       ├─ CodexTranscript (observable)        # ThreadItem → display model
       └─ approval/context bridges            # reuse LocalApprovalStore + LocalWhiteboardStore
```

### SessionBackend protocol (new, thin)

Extract the control surface that the runner/UI already uses from `AgentTerminalSession`:

```swift
protocol SessionBackend: AnyObject {
    var statusPublisher: Published<SessionStatus>.Publisher { get }   // running/idle/completed/failed
    func send(_ text: String)        // claude: write to PTY · codex: turn/start (or steer, later)
    func interrupt()                 // claude: ESC · codex: turn/interrupt
    func stop()                      // claude: SIGTERM→SIGKILL · codex: close + terminate child
}
```

- `AgentTerminalSession` conforms (claude) — minimal refactor, keeps SwiftTerm.
- `CodexAppServerBackend` conforms (codex) — new.
- `CrewSessionRun` holds a `SessionBackend` instead of a concrete `AgentTerminalSession`.
- The inspector view picks the concrete view by kind: `.claudeCode` → `AgentTerminalView` (SwiftTerm); `.codex` → `CodexTranscriptView`. The protocol covers control; the view is chosen by type.

### CodexAppServerConnection (actor) — the JSON-RPC client

- Spawns `codex app-server` with `cwd`, clean env, and `-c model_reasoning_effort=<effort>` (spec §5: `-c` on spawn is deterministic; `config.toml` overrides turn-level effort).
- Reads stdout line-by-line; each line is one JSON value (newline-delimited, `jsonrpc` omitted on wire). Routes by shape:
  - has `id` + (`result`|`error`), no `method` → **response** to one of *our* requests → resume the continuation in the **client-id map**.
  - has `method` + `id` → **server-initiated request** (approvals) → handle, reply with the **server's** id.
  - has `method`, no `id` → **notification** (streaming events) → feed transcript.
- Two independent id directions (both can use `id:0`): our outgoing requests (we number them) and the server's incoming requests (it numbers them). Keep them separate — never one shared map.
- Outbound API: `request(method, params) async throws -> JSON`, `notify(method, params)`, `respond(serverId, result)`.

### Protocol models (`CodexProtocol.swift`) — core-loop subset only

initialize / initialized · `account/read` · `thread/start` · `turn/start` · `turn/interrupt` · streaming notifications (`thread/started`, `turn/started`, `item/started`, `item/completed`, `turn/completed`) · the three `*/requestApproval` server requests + `serverRequest/resolved`. Decodable structs, version-locked to the reference; unknown fields ignored.

### CodexThreadItem → CodexTranscriptView

`CodexThreadItem` enum maps the union: `userMessage · agentMessage · reasoning · plan · commandExecution{command,cwd,status,output,exitCode} · fileChange{changes,status} · mcpToolCall · dynamicToolCall · collabAgentToolCall · webSearch · contextCompaction · unknown(raw)`. The `.unknown` arm renders raw and never crashes on a new codex type.

- v1 **opts out of delta notifications** (`initialize…optOutNotificationMethods`), renders on `item/completed` (authoritative final). No token-by-token streaming in v1 → defer to v1.x.
- `CodexTranscriptView`: per-arm SwiftUI rows — message bubbles, collapsible reasoning, command-exec card (cmd + output + exit code), file-diff, tool-call. Style reference: codex's own TUI (Apache-2.0) + `shuto-S/codex-app-mobile` (SwiftUI) — patterns only, verify license before copying any code.

### Context injection (replaces claude's flag + hook)

codex has no `--append-system-prompt-file` / no PostToolUse hook. Instead:
- **World-model** (startup system prompt): render the same `LocalSessionWorldModel` markdown, pass via `thread/start.developerInstructions`. (append-vs-replace semantics → confirm once on real machine.)
- **Whiteboard** (per-turn unread): each `turn/start` carries `additionalContext:{ whiteboard:{ value:<unread>, kind:"untrusted" } }`, read from the same `LocalWhiteboardStore` claude uses.
- **post_to_crew / read_whiteboard / ask tools**: wire the existing `pendingcrew-mcp serve` into codex via its `mcp_servers` config (codex natively supports MCP). Same helper, same store.

### Approvals (low-frequency — reuse, don't build a subsystem)

A `*/requestApproval` server request → raise a pending entry in the existing `LocalApprovalStore` (keyed by sessionId, carrying `availableDecisions` for the buttons) → existing approval UI renders → on human decision, `respond(serverId, {decision})` over stdin → `serverRequest/resolved` dismisses. The only codex-specific bit vs claude is "reply over stdin" instead of "hook exit". Policy: `approvalPolicy:"on-request"` + `sandbox:"workspace-write"` + `approvalsReviewer:"user"`.

## Lifecycle

starting → (turn active = running / between turns = idle) → completed/failed. `interrupt()` → `turn/interrupt`; `stop()` → close stdin + terminate child (SIGTERM→SIGKILL backstop, same as terminal). `serverLink.finish()` finalize unchanged.

## Scope — core loop (confirmed)

**IN**: spawn + initialize handshake + `account/read` gate · `thread/start` (cwd, developerInstructions, mcp_servers, approval policy) · `turn/start` (initial + subsequent `send`, whiteboard additionalContext) · stream `item/completed` → transcript · `interrupt` / `stop` · approvals → existing UI · crew MCP wired · effort via `-c`.

**DEFER → tech-debt**: delta/token streaming · `turn/steer` mid-turn injection · `resume`/`fork` · rate-limit display · peer rollout JSONL cross-read · hooks system.

## Testing

- **Unit (TDD, mock stdio — no real codex)**: JSON-RPC framing encode/decode (newline-delimited, `jsonrpc` omitted) · two-id-direction routing · `CodexThreadItem` decode from fixtures · turn state machine · approval request→store→reply roundtrip · additionalContext assembly · env omits `OPENAI_API_KEY`.
- **Real-machine tail (needs user: codex login + Xcode GUI build)**: ① which auth model the installed codex uses (auto `~/.codex/auth.json` vs client-driven `account/login/start`); ② real handshake + one turn rendering end-to-end; ③ approval roundtrip; ④ `developerInstructions` append-vs-replace; ⑤ billing tick (usedPercent ↑, nothing on API dashboard). Logged to tech-debt as a manual verification item — do not mark the feature "done" on unit-green alone.

## Files

New (`Sources/Mac/LocalRunner/CodexAppServer/`): `CodexAppServerConnection.swift` · `CodexProtocol.swift` · `CodexThreadItem.swift` · `CodexTranscript.swift` · `CodexAppServerBackend.swift`. New view: `Sources/Mac/Views/CodexTranscriptView.swift`.
Touched: `SessionBackend.swift` (new protocol) · `AgentTerminalSession.swift` (conform) · `CrewSessionRunner.swift` (hold `SessionBackend`, pick by kind) · `SessionConfig.swift` (codex branch → app-server spawn args, drop placeholder) · `LocalSessionLaunch.swift` (codex variant: world-model string + whiteboard provider + codex MCP config) · inspector view (branch by kind).

## References

- `2026-06-05-codex-app-server-reference.md` (internal, empirical protocol)
- [OpenAI: App Server](https://developers.openai.com/codex/app-server) · [openai/codex app-server README](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md)
- [shuto-S/codex-app-mobile](https://github.com/shuto-S/codex-app-mobile) (SwiftUI client, pattern reference)
