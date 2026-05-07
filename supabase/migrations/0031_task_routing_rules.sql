-- Per-task LLM routing overrides. Sits in front of resolveRoute() in
-- the edge router: when a caller passes a task_type, the router looks
-- for an enabled rule matching that task and applies any non-null
-- overrides before doing the normal alias lookup.
--
-- Two override knobs, both optional:
--
--   override_model_id    Replace the bot's chosen model entirely. Useful
--                        for pinning cheap auxiliary tasks ('title',
--                        'ai_picks', 'lookback') to a small fast model
--                        regardless of what model the bot itself uses
--                        for the conversation.
--
--   prefer_provider_id   Bias provider selection toward this provider
--                        when the same model has aliases on multiple
--                        providers. Translates to RouteResolveOpts.
--                        preferProvider in the router.
--
-- Both null = the rule still useful as a marker / annotation (and as a
-- placeholder you can fill in later) but has no routing effect.
--
-- Match precedence: when more than one enabled rule exists for the
-- same task_type (which a unique constraint prevents at the same
-- match_priority), the lowest match_priority wins. Picking a single
-- rule per task_type is intentional — chained overrides get hard to
-- reason about in incidents.

BEGIN;

CREATE TABLE pendingbot.task_routing_rules (
    id uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    task_type text NOT NULL,
    -- Lower wins. 100 is the suggested default; reserve 0–10 for
    -- emergency overrides ("force-off WorldRouter for all tasks").
    match_priority integer DEFAULT 100 NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    override_model_id uuid,
    prefer_provider_id uuid,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT task_routing_rules_pkey PRIMARY KEY (id),
    -- Allow multiple rules per task_type only when their priorities
    -- differ — the router picks the lowest. Same priority ties would
    -- be a non-deterministic outcome.
    CONSTRAINT task_routing_rules_task_priority_uniq
      UNIQUE (task_type, match_priority),
    CONSTRAINT task_routing_rules_override_model_fkey
      FOREIGN KEY (override_model_id) REFERENCES pendingbot.llm_models(id)
      ON DELETE SET NULL,
    CONSTRAINT task_routing_rules_prefer_provider_fkey
      FOREIGN KEY (prefer_provider_id) REFERENCES pendingbot.llm_providers(id)
      ON DELETE SET NULL
);
ALTER TABLE pendingbot.task_routing_rules OWNER TO postgres;

-- Hot path: "for this task_type, give me the lowest-priority enabled rule"
CREATE INDEX idx_task_routing_lookup
  ON pendingbot.task_routing_rules(task_type, enabled, match_priority);

ALTER TABLE pendingbot.task_routing_rules ENABLE ROW LEVEL SECURITY;
-- service_role only, like the rest of the admin schema.

GRANT SELECT, INSERT, UPDATE, DELETE
  ON TABLE pendingbot.task_routing_rules TO service_role;

COMMIT;
