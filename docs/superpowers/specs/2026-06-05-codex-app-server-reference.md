# Codex `app-server` Integration Reference (PendingCrew codex Phase 2)

**2026-06-05** — empirically verified against `codex-cli 0.137.0` (live probes + locally generated protocol bindings). Feeds the codex-backend plan. **Regenerate protocol on every codex upgrade** (version-locked):
`codex app-server generate-ts --out ./codex-proto-ts --experimental` + `generate-json-schema --out ./codex-proto-schema --experimental` (v2 surface under `v2/`; routers `ClientRequest`/`ServerRequest`/`ServerNotification`/`ClientNotification`).

Legend: ✅ doc · 🔬 verified on 0.137.0 · 📄 generated-schema · ⚠️ needs-a-run.

## 0. 🔴 BILLING — the critical confirmation (✅🔬)
**app-server bills the ChatGPT subscription** when `~/.codex/auth.json` has `auth_mode:"chatgpt"`. The **credential** picks the credit pool, **not** the entrypoint (`exec`/TUI/app-server all identical).
- Live: `account/read` → `{"account":{"type":"chatgpt","email":"…","planType":"prolite"},"requiresOpenaiAuth":true}`. `account/rateLimits/read` shows partially-consumed ChatGPT plan windows (weekly at 55%) = live subscription counter.
- Docs: API key → "standard API pricing instead of included ChatGPT plan credits"; CLI/IDE/app share `~/.codex/auth.json`, no per-entrypoint split.
- ⚠️ **Ensure no `OPENAI_API_KEY` is exported into the app-server process env** (env key can flip auth→apikey/pay-as-you-go despite `auth_mode:"chatgpt"`). auth.json having an `OPENAI_API_KEY` field is fine; an exported env var is the risk.
- ⚠️ Production-account final check: run a real turn, confirm `usedPercent` ticks up + nothing on API billing dashboard; watch `RateLimitReachedType` for `*_credits_depleted` on metered plans.

## 0b. Transport / handshake (🔬📄✅)
- Spawn `codex app-server` (stdio default). Newline-delimited JSON, JSON-RPC 2.0 **with `"jsonrpc"` omitted on the wire**.
- Request `{method,id,params}` → response `{id,result|error}`. Notification `{method,params}` (no id).
- **Mandatory first**: `initialize` → `InitializeResponse` → `initialized` notification. Calls before init → `"Not initialized"`.
- Opt into v2 experimental fields: `initialize.params.capabilities.experimentalApi:true`. Optional `optOutNotificationMethods:["item/agentMessage/delta", …]`.
- **Server→client requests have their OWN id sequence** (first approval came as `id:0` while client ids were 1,2,3…). Track server-request ids separately.

## 1. Thread/turn (use **v2**, not legacy v1) (📄✅🔬)
- **`thread/start`** `{model?, cwd?, approvalPolicy?, sandbox?|permissions?(profile, mutually exclusive), approvalsReviewer?, baseInstructions?, developerInstructions?, config?:{inline overrides}, …}` → `{thread, model, cwd, approvalPolicy, sandbox, reasoningEffort, …}`. `thread.id` = session id. Also emits `thread/started`.
- **`turn/start`** (initial prompt) `{threadId, input:[{type:"text",text,text_elements:[]}], model?, effort?, approvalPolicy?, sandboxPolicy?|permissions?, additionalContext?, outputSchema?}` → `{turn}`. `UserInput` variants: text/image/localImage/skill/mention.
- **Streaming order (🔬)**: `thread/started → turn/started → (item/started → [deltas] → item/completed)* → thread/tokenUsage/updated → account/rateLimits/updated → turn/completed`. `item/completed` = authoritative final state per item.
- **`ThreadItem` union** (display model 1:1): `userMessage·agentMessage{text,phase}·reasoning{summary,content}·plan·commandExecution{command,cwd,status,aggregatedOutput,exitCode}·fileChange{changes[],status}·mcpToolCall·dynamicToolCall·collabAgentToolCall(子agent)·webSearch·contextCompaction·…`. `turn/diff/updated` gives an aggregated unified diff for the whole turn (single "what changed" view).
- **Interrupt**: `turn/interrupt {threadId,turnId}` → server emits `turn/completed status:"interrupted"`.

## 2. Approvals → captain→human (NOT auto_review) (✅📄🔬)
**Setup**: `approvalPolicy:"on-request"` + `sandbox:"workspace-write"` + **`approvalsReviewer:"user"`** (default; routes the request OUT to us, not an internal subagent). `ApprovalsReviewer = user | auto_review | guardian_subagent` — we use `"user"`.
- Boundary crossing → server sends a **JSON-RPC request** (blocks agent, we must reply): `item/commandExecution/requestApproval` / `item/fileChange/requestApproval` / `item/permissions/requestApproval`.
- Live capture: command-exec approval carries `{reason, command, cwd, commandActions[], proposedExecpolicyAmendment, availableDecisions[]}`. Reply `{"id":<same>,"result":{"decision":"accept"|"decline"|"cancel"|{"acceptWithExecpolicyAmendment":…}}}`.
- **Confirmed: can hold arbitrarily long → hand to captain→human, reply async over stdio.** `serverRequest/resolved {threadId,requestId}` fires after → dismiss UI. `availableDecisions` = exactly which buttons to render. **This is §9 Layer-2 native for codex.**

## 3. Context injection mid-session (live whiteboard) (✅📄)
- **Between turns**: just `turn/start` again on same threadId.
- **During a running turn**: **`turn/steer`** `{threadId, input[], expectedTurnId:<active>, additionalContext?}` → `{turnId}`. Appends to the running turn; `expectedTurnId` is a CAS guard. ← closest to live-whiteboard mid-think.
- **Per-turn labeled context**: `additionalContext:{[sourceId]:{value,kind:"untrusted"|"application"}}` on turn/start|steer. `kind:"untrusted"` = data-not-instructions (injection hygiene). ← inject whiteboard each turn here.
- **History splice**: `thread/inject_items {threadId, items[]}` (raw Responses API items, no turn). Lower-level.
- Codex has a hooks system over protocol (`hooks/list`, `hook/started|completed`, `HookEventName`) — ⚠️ enumerate `v2/HookEventName.ts` if a true pre-prompt hook is wanted; `additionalContext` is simpler for most needs.

## 4. Usage / rate limits (✅📄🔬)
- **Tokens**: `thread/tokenUsage/updated {tokenUsage:{total,last:{totalTokens,inputTokens,cachedInputTokens,outputTokens,reasoningOutputTokens}, modelContextWindow}}`.
- **Rate limits**: push `account/rateLimits/updated` (sparse → merge into last snapshot) + pull `account/rateLimits/read`. Window = `{usedPercent, windowDurationMins, resetsAt(epoch sec)}`. `primary`=5h(300m), `secondary`=weekly(10080m). Multi-bucket via `rateLimitsByLimitId`. `RateLimitReachedType` ∈ rate_limit_reached|*_credits_depleted|*_usage_limit_reached. ← **§7 额度监控 codex 侧,直接读。**

## 5. Effort (📄✅🔬)
- `ReasoningEffort` enum: `none|minimal|low|medium|high|xhigh` (GPT-5.x advertise `[low,medium,high,xhigh]` via `model/list.supportedReasoningEfforts`).
- Set: `codex -c model_reasoning_effort=high app-server` (spawn) / `thread/start.config` / `turn/start.effort`.
- ⚠️ **GOTCHA (🔬)**: `config.toml`'s `model_reasoning_effort` **overrode** `thread/start.effort` (user config has `xhigh`). → set effort via **`-c` on spawn** for determinism; verify `turn/start.effort` per-turn precedence with one run before trusting. Invalid effort strings **silently fall back** (no error) → validate client-side.

## 6. Resume + cross-read (✅📄🔬)
- Rollout JSONL: `~/.codex/sessions/YYYY/MM/DD/rollout-<ISO-dashes>-<uuid>.jsonl`; **filename uuid == thread/session id**. Lines: `session_meta`(1st, has `forked_from_id`,`thread_source`) · `turn_context` · `response_item`(message/reasoning/function_call/…) · `event_msg`(`token_count` carries `rate_limits` snake_case). → **§10 跨读 codex 侧 = parse peer rollout JSONL offline**.
- Over protocol: `thread/read {threadId,includeTurns?}` / `thread/list` / `thread/turns/list` / `thread/search` (same shapes as live stream).
- **Resume**: `thread/resume {threadId, …overrides}` (rejoins if running elsewhere). **Fork**: `thread/fork {threadId|path}` (branch, sets `forkedFromId`).

## Confirmed vs needs-a-run
**Build to now (✅🔬📄)**: transport/handshake, thread/turn + streaming items + interrupt, approval RPCs→"user"→async reply, turn/steer + additionalContext, token+rate-limit reads, **billing=subscription**, effort enum + `-c` override, rollout JSONL + resume/fork.
**⚠️ needs-a-run**: turn-level effort precedence vs config; client-side effort validation; `HookEventName` variants (only if true pre-prompt hook wanted); production-account billing tick; no `OPENAI_API_KEY` in app-server env.
