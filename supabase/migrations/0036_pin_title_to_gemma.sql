-- Pin the 'title' task to google/gemma-4-31b-it so the conv-title
-- summarizer doesn't burn the bot's chat model (Opus/GPT-5/etc.) on
-- a 10-character output. Title runner already passes taskType='title'
-- through resolveRoute(); this rule is what actually swaps the model.
--
-- Two steps:
--
--   1. Register the model in llm_models so the FK on
--      task_routing_rules.override_model_id resolves. We don't seed an
--      llm_model_aliases row — the resolveRoute() passthrough fallback
--      will hand the slug to OpenRouter as-is. Cost won't be tracked on
--      the audit row (alias=null → cost_usd=null) until admin adds an
--      alias with pricing via the panel; that's an acceptable trade for
--      a cheap auxiliary task.
--
--   2. Upsert the routing rule at the default priority (100). ON
--      CONFLICT updates override_model_id so re-running this migration
--      after the model row was deleted/recreated still settles to the
--      right state.

BEGIN;

INSERT INTO pendingbot.llm_models (slug, family, display_name, notes)
VALUES (
    'google/gemma-4-31b-it',
    'gemma',
    'Gemma 4 31B Instruct',
    'Used for cheap auxiliary tasks (title generation). Routed via OpenRouter passthrough — no alias seeded, so audit rows have null cost until admin curates pricing.'
)
ON CONFLICT (slug) DO NOTHING;

INSERT INTO pendingbot.task_routing_rules (
    task_type, match_priority, enabled, override_model_id, notes
)
SELECT
    'title',
    100,
    true,
    m.id,
    'Pin conv-title summarizer to a small fast model so it doesn''t use the bot''s chat model.'
FROM pendingbot.llm_models m
WHERE m.slug = 'google/gemma-4-31b-it'
ON CONFLICT (task_type, match_priority) DO UPDATE
SET override_model_id = EXCLUDED.override_model_id,
    enabled = EXCLUDED.enabled,
    notes = EXCLUDED.notes,
    updated_at = now();

COMMIT;
