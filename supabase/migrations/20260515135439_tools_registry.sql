-- 20260515135439_tools_registry.sql
--
-- Single registry of every tool the LLM can be advertised, regardless
-- of whether the runtime dispatch is native code (apps/edge/src/lib/
-- bot-reply/tools/*) or an MCP upstream (apps/edge/src/mcp/client.ts).
--
-- Goals:
--   1. Board "Tools" page can list every tool in one table, with an
--      enable/disable toggle. Crucially, for MCP-server tools the
--      admin picks which advertised tools to expose — the upstream
--      may list more than we want the model to see.
--   2. Edge filters its assembled tool list against this table before
--      sending to the model. Disabling a tool here is the kill-switch
--      that doesn't require a deploy.
--
-- Native vs MCP dispatch is unchanged for v1 — this table is a *filter*
-- + metadata layer, not a runtime dispatcher.
--
-- Replaces a legacy `pendingbot.tools` table from 0001_init that was
-- never wired into the edge runtime (no code reads from it; grep
-- confirms zero non-schema references). We drop it and recreate with
-- the new shape, then patch the one cleanup function that still
-- mentions it (`_before_auth_user_delete` from 0052).

BEGIN;

DROP TABLE IF EXISTS pendingbot.tools CASCADE;

CREATE TABLE pendingbot.tools (
    id                uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    -- Tool name as the LLM sees it (function.name on the OpenAI tool
    -- envelope). Matches the native handler key or the upstream MCP
    -- tool name.
    key               text NOT NULL,
    kind              text NOT NULL,
    -- For kind='mcp', which server advertises this tool. ON DELETE
    -- CASCADE so removing a server sweeps its tool rows.
    mcp_server_id     uuid,
    -- Surface scopes — which assembly paths advertise this tool.
    -- 'chat' = bot-reply, 'envelope' = envelope-runner. JSON array so
    -- a single tool can live on multiple surfaces (most native tools).
    scopes            jsonb NOT NULL DEFAULT '[]'::jsonb,
    description       text,
    enabled           boolean NOT NULL DEFAULT true,
    notes             text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT tools_pkey PRIMARY KEY (id),
    CONSTRAINT tools_key_uniq UNIQUE (key),
    CONSTRAINT tools_kind_chk CHECK (kind IN ('native','mcp')),
    CONSTRAINT tools_mcp_fkey FOREIGN KEY (mcp_server_id)
        REFERENCES pendingbot.mcp_servers(id) ON DELETE CASCADE,
    CONSTRAINT tools_kind_consistency_chk CHECK (
        (kind = 'native' AND mcp_server_id IS NULL)
     OR (kind = 'mcp'    AND mcp_server_id IS NOT NULL)
    )
);
ALTER TABLE pendingbot.tools OWNER TO postgres;

COMMENT ON TABLE pendingbot.tools IS
    'Registry of all LLM tools (native + MCP). Edge reads on a 60s '
    'isolate cache and filters advertised tools to enabled=true rows.';

CREATE INDEX idx_tools_kind_enabled
    ON pendingbot.tools(kind, enabled);

CREATE INDEX idx_tools_mcp_server
    ON pendingbot.tools(mcp_server_id)
    WHERE mcp_server_id IS NOT NULL;

ALTER TABLE pendingbot.tools ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.tools TO service_role;

-- ── Patch _before_auth_user_delete ───────────────────────────────────
-- The legacy tools table had an owner_id column the cleanup trigger
-- defensively nullified. The new tools table has no owner concept —
-- everything is global registry — so drop that line. Rest of the body
-- is identical to 0052_auth_delete_user_trigger.sql; we recreate it
-- here so the trigger picks up the new definition.

CREATE OR REPLACE FUNCTION pendingbot._before_auth_user_delete()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
declare
  p_uid uuid := old.id;
  my_conv_ids uuid[];
  my_message_ids uuid[];
begin
  delete from pendingbot.bots
   where creator_id = p_uid and visibility = 'private';

  select coalesce(array_agg(id), '{}') into my_conv_ids
    from pendingbot.conversations where user_id = p_uid;
  select coalesce(array_agg(id), '{}') into my_message_ids
    from pendingbot.messages
   where user_id = p_uid or conversation_id = any(my_conv_ids);

  update pendingbot.messages set parent_message_id = null
   where parent_message_id = any(my_message_ids);
  update pendingbot.messages set replaces_message_id = null
   where replaces_message_id = any(my_message_ids);
  update pendingbot.messages set replaced_by_message_id = null
   where replaced_by_message_id = any(my_message_ids);

  update pendingbot.audit_log set conversation_id = null
   where conversation_id = any(my_conv_ids);
  update pendingbot.audit_log set user_id = null where user_id = p_uid;

  update pendingbot.invites set created_by = null where created_by = p_uid;
  update pendingbot.invites set used_by = null where used_by = p_uid;

  -- (legacy `update pendingbot.tools set owner_id = null` removed —
  -- the new tools table has no owner concept; entries are global.)

  delete from pendingbot.skills where owner_id = p_uid;
  delete from pendingbot.attachments where user_id = p_uid;

  delete from pendingbot.messages where user_id = p_uid;
  delete from pendingbot.conversation_participants
   where participant_type = 'user' and participant_id = p_uid;
  delete from pendingbot.conversations where user_id = p_uid;

  return old;
end $$;

ALTER FUNCTION pendingbot._before_auth_user_delete() OWNER TO postgres;

-- ── Seed: native chat + envelope tools ───────────────────────────────
-- Mirrors apps/edge/src/lib/bot-reply/tool-defs.ts and
-- apps/edge/src/lib/envelope-loop.ts. Conditional exposure
-- (group-only nicknames, skill-gated execute_code) stays in code; this
-- table answers only "is the tool allowed at all" + "on which surface".

INSERT INTO pendingbot.tools (key, kind, scopes, description) VALUES
    ('query_user_memory',         'native', '["chat","envelope"]'::jsonb, 'Honcho 长记忆检索：从用户跨会话历史里取上下文'),
    ('search_chat_history',       'native', '["chat","envelope"]'::jsonb, '当前会话内的全文检索'),
    ('read_attachment',           'native', '["chat","envelope"]'::jsonb, '用视觉模型重新读图片附件'),
    ('create_skill',              'native', '["chat","envelope"]'::jsonb, '把工作流写成 skill 入库并自动订阅'),
    ('request_execute_code',      'native', '["chat","envelope"]'::jsonb, '请求用户授权后跑 Python sandbox'),
    ('execute_code',              'native', '["chat","envelope"]'::jsonb, '免授权直接跑 Python sandbox（需 skill allowed_tools 显式开启）'),
    ('set_my_group_nickname',     'native', '["chat"]'::jsonb,            '群聊里改自己的群昵称（仅 inGroup 时）'),
    ('set_bot_group_description', 'native', '["chat"]'::jsonb,            '群聊里改 "什么时候叫我" 的描述（仅 inGroup 时）'),
    ('propose_plan',              'native', '["envelope"]'::jsonb,        '写信探索阶段：和协作模型对齐方向'),
    ('web_search',                'native', '["envelope"]'::jsonb,        '写信探索阶段：内部 web_search 包装（转发到 Exa MCP）'),
    ('fetch_url',                 'native', '["envelope"]'::jsonb,        '写信探索阶段：内部 fetch_url 包装（转发到 Exa MCP）'),
    ('take_note',                 'native', '["envelope"]'::jsonb,        '写信探索阶段：记录关键发现到长期 note'),
    ('stop_exploring',            'native', '["envelope"]'::jsonb,        '写信探索阶段：结束探索进入写作阶段');

-- ── Seed: MCP tools from the Exa server row ─────────────────────────
-- The mcp_server_id is resolved via subquery so the seed remains
-- replayable even if the Exa row gets re-created with a different id.

INSERT INTO pendingbot.tools (key, kind, mcp_server_id, scopes, description)
SELECT
    'web_search_exa', 'mcp', s.id, '["chat"]'::jsonb,
    'Exa 神经/关键词/auto 搜索（Exa MCP）'
FROM pendingbot.mcp_servers s WHERE s.name = 'exa';

INSERT INTO pendingbot.tools (key, kind, mcp_server_id, scopes, description)
SELECT
    'web_fetch_exa', 'mcp', s.id, '["chat"]'::jsonb,
    'Exa /contents 抓页内容（Exa MCP）'
FROM pendingbot.mcp_servers s WHERE s.name = 'exa';

COMMIT;
