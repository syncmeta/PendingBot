# Crew runner steering via context injection (verified 2026-06-02)

How a cross-device viewer steers a *running* crew session (T4.5 `send_prompt`)
**without** rearchitecting the one-shot runner and **without** breaking the
prompt cache. Records a headless experiment with the real `claude` CLI
(2.1.156) and the cache numbers behind the recommendation.

## The question

T4.5 viewers can already watch a session (live `session.state`) and `cancel`
it. The open piece is `send_prompt`: feed a follow-up instruction to an
agent that's already running on the Mac. The naive idea — pipe the prompt to
the CLI's stdin — doesn't work: `claude --print` reads stdin **once** and runs
to completion; there's no interactive stdin loop. The alternative idea (from
the design discussion): inject the instruction **as context** that the agent
just "sees", with no read action — and crucially, don't invalidate the prompt
cache by doing so.

## The experiment

Isolated temp project, all tools disabled (`--allowedTools ""`) so the model
could **not** read any file. A `UserPromptSubmit` hook read a `steering.md`
and emitted its content as `hookSpecificOutput.additionalContext`. A secret
codeword lived only in `steering.md`.

```
hook: UserPromptSubmit → jq -nc '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:<cat steering.md>}}'
```

Findings:

1. **Injection works, no read action.** Turn 1 asked for the codeword with
   tools off; the model answered the secret (`BANANA-7741`). The only path
   for it to know was the hook's `additionalContext`. The hook log confirmed
   firing.
2. **Live per-turn.** Edited `steering.md` (v1→v2), `--resume`d the session,
   asked again → model returned the **new** value (`MANGO-9920`). The hook
   re-reads + re-injects every turn, so the file is a live steering channel.
3. **Cache-safe — this is the load-bearing result.** Per-turn cache usage:

   | turn | what changed | cache_create | cache_read |
   |------|--------------|-------------:|-----------:|
   | 1 | baseline | 9584 | 11362 |
   | 2 | steering changed, injected at **tail** (UserPromptSubmit) | **79** | **20946** |
   | 3 | steering changed, injected at **prefix** (`--append-system-prompt`, changing nonce) | **9760** | 11367 |

   Tail injection (turn 2): the stable prefix stayed cached (read 20946), only
   ~79 new tokens were written. Prefix injection (turn 3): the changed system
   prompt invalidated everything downstream — ~9760 tokens **re-created every
   turn**, read fell back to the base.

## The rule

- **Inject steering at the tail** — `UserPromptSubmit` `additionalContext`, i.e.
  riding with the new user turn. The cached prefix (system prompt + tools +
  prior turns) is immutable history, so it stays a cache hit.
- **Never inject into the cached prefix.** Anything that rewrites the front
  every turn — `--append-system-prompt` with changing content, regenerating
  `CLAUDE.md` / `SessionStart` context mid-session — busts the prefix cache and
  re-bills the whole conversation each turn.

## Recommended design for T4.5 `send_prompt`

The one-shot runner stays one-shot; steering becomes a **new resumed turn**:

1. Viewer's `send_prompt` (or any steering) → enqueue to the existing
   **session mailbox** (`enqueue_session_mailbox`, already shipped in the DO).
2. The runner, when the current `claude -p` turn finishes (or idles), issues
   `claude --resume <sessionId> -p "<viewer prompt>"`. `--resume` reuses the
   cached prefix (the experiment's turn-2 cache_read 20946 ≈ free), so each
   steering turn is cheap.
3. A `UserPromptSubmit` hook on the run folds any out-of-band steering file /
   pending mailbox items into `additionalContext` — additive, never replacing
   the task, so it doesn't conflict with what the agent is already doing.

Granularity note: this steers at **turn boundaries** (after the current
agentic step completes), not mid-token. That's the right granularity for
"add this instruction" and avoids the stdin rearchitecture. True sub-turn
interruption would still need bidirectional `--input-format stream-json`; most
steering doesn't.

Open item before building: confirm hook + `--resume` behaviour with **tools
enabled** and a real multi-step agentic turn (the experiment disabled tools to
isolate the injection proof). The runner today shells `claude -p` directly; if
hook coverage proves uneven, the Agent SDK is the fallback host.
