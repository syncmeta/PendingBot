-- 0002_scroll — replace surf with 奏折/Scroll.
--
-- Scroll is what surf was meant to be: a bot 进谏 to its user. The bot
-- reads its own conversation with this user (transcript + memory),
-- optionally surfs the web for grounding facts, and writes a single
-- article. The article surfaces in a dedicated 奏折 tab on iOS, not as
-- log messages in a host conv.
--
-- Each scroll_runs row IS one article — when the runner finishes it
-- writes title/summary/body_md and flips status='done'. Empty / silent
-- runs are deleted before they ever appear in the feed.
--
-- The previous surf_runs table + route + prompts are removed wholesale
-- (the runner was a stub; the user is replacing the design).

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET search_path TO pendingbot, public;

-- ── Drop the old surf scaffolding ─────────────────────────────────────
-- Realtime publication first (you can't drop a table that's still in a
-- publication's active set).
ALTER PUBLICATION supabase_realtime DROP TABLE pendingbot.surf_runs;
DROP TABLE pendingbot.surf_runs;
-- Note: conversations.conversation_type CHECK constraint still allows
-- 'surf' as a value. Leaving it for now — no rows use it, and tightening
-- the CHECK can come in a later cleanup pass.

-- ── New scroll_runs ───────────────────────────────────────────────────
CREATE TABLE pendingbot.scroll_runs (
    id uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    conversation_id uuid NOT NULL,
    user_id uuid NOT NULL,
    bot_id uuid NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    progress jsonb DEFAULT '{}'::jsonb NOT NULL,
    title text,
    summary text,
    body_md text,
    cost_budget_usd numeric(10,4),
    cost_used_usd numeric(10,4) DEFAULT 0 NOT NULL,
    trigger text,
    started_at timestamp with time zone,
    finished_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT scroll_runs_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'running'::text, 'done'::text, 'error'::text, 'cancelled'::text])))
);

ALTER TABLE pendingbot.scroll_runs OWNER TO postgres;

ALTER TABLE ONLY pendingbot.scroll_runs
    ADD CONSTRAINT scroll_runs_pkey PRIMARY KEY (id);

ALTER TABLE ONLY pendingbot.scroll_runs
    ADD CONSTRAINT scroll_runs_bot_id_fkey FOREIGN KEY (bot_id)
    REFERENCES pendingbot.bots(id);

-- conversation_id is the source the bot read from (the user_bot conv).
-- The article does NOT live in that conv — it lives in the scroll feed.
ALTER TABLE ONLY pendingbot.scroll_runs
    ADD CONSTRAINT scroll_runs_conversation_id_fkey FOREIGN KEY (conversation_id)
    REFERENCES pendingbot.conversations(id) ON DELETE CASCADE;

ALTER TABLE ONLY pendingbot.scroll_runs
    ADD CONSTRAINT scroll_runs_user_id_fkey FOREIGN KEY (user_id)
    REFERENCES auth.users(id) ON DELETE CASCADE;

-- Feed paging: order by (user_id, created_at desc).
CREATE INDEX idx_scroll_runs_feed
    ON pendingbot.scroll_runs USING btree (user_id, created_at DESC);

CREATE INDEX idx_scroll_runs_conv
    ON pendingbot.scroll_runs USING btree (conversation_id);

ALTER TABLE pendingbot.scroll_runs ENABLE ROW LEVEL SECURITY;

CREATE POLICY scroll_self ON pendingbot.scroll_runs
    FOR SELECT USING ((user_id = auth.uid()));

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.scroll_runs TO authenticated;
GRANT SELECT ON TABLE pendingbot.scroll_runs TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE pendingbot.scroll_runs TO service_role;

-- Realtime: iOS subscribes so the feed and the in-progress shimmer
-- update without polling.
ALTER PUBLICATION supabase_realtime ADD TABLE pendingbot.scroll_runs;
