-- Local heuristic token estimate columns. Filled in edge by a tiny
-- char-based estimator before each LLM call (see apps/edge/src/llm/
-- token-estimate.ts) and persisted alongside the provider-reported
-- input_tokens / output_tokens. Lets the audit panel show a
-- provider-vs-local ratio per row — outliers are the signal we want
-- when a budget router (e.g. WorldRouter) might be padding billed
-- tokens.
--
-- Nullable on purpose: not every audit_log writer wires the estimator
-- (cheap one-off calls, scroll-runner background jobs, etc.). NULL =
-- "no local estimate computed", which the panel renders as '—'.

ALTER TABLE pendingbot.audit_log
  ADD COLUMN est_input_tokens int,
  ADD COLUMN est_output_tokens int;

COMMENT ON COLUMN pendingbot.audit_log.est_input_tokens IS
  'Local heuristic estimate of input tokens (chars/4 ASCII + chars/1.5 CJK + per-message framing). Sanity-check signal against provider-reported input_tokens; large divergence may indicate provider-side billing inflation.';
COMMENT ON COLUMN pendingbot.audit_log.est_output_tokens IS
  'Local heuristic estimate of output tokens (assistant text + tool_call name+arguments JSON). Mirror of est_input_tokens for the model''s output.';
