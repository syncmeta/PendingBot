-- 20260517140049_tools_model_description_required.sql
--
-- Make tools.model_description the single source of truth for the
-- model-facing description of native tools. Until now the text was
-- duplicated: hardcoded in apps/edge/src/lib/bot-reply/tool-defs.ts and
-- apps/edge/src/lib/envelope-loop.ts, AND mirrored into model_description
-- as a board-editable "override" that fell back to the code copy when
-- NULL. That fallback is gone — the edge code no longer carries native
-- tool descriptions at all, so the board row IS the description.
--
-- Two parts:
--   1. Seed the 5 envelope-stage native tools whose model_description was
--      never populated by 20260517111840 (that migration only covered the
--      chat-side tools). Verbatim from envelope-loop.ts TOOLS.
--   2. Add a CHECK: native tools must carry a non-empty model_description.
--      MCP tools may stay NULL — their description comes from the upstream
--      MCP server, which is genuinely external and not in our code.

BEGIN;

UPDATE pendingbot.tools SET model_description = $desc$说明你的思考、想搜的关键词、想直接抓取的网页。协作者会回应——这是和协作者来回讨论方案的工具。如果 web_search / fetch_url 此刻被锁着（系统会暂停它们），就先用 propose_plan 把方向打磨清楚。$desc$
WHERE key = 'propose_plan';

UPDATE pendingbot.tools SET model_description = $desc$用配置好的搜索服务商搜索 query，返回若干结果（标题/URL/摘要）。**搜索结果只在本轮可见——下一轮会被精简成占位符，值得记的请立刻用 take_note 记下，否则就忘了。**$desc$
WHERE key = 'web_search';

UPDATE pendingbot.tools SET model_description = $desc$用配置好的爬虫服务商抓取一个网页的正文。**抓回的页面正文只在本轮可见——下一轮会被精简成占位符，值得记的请立刻用 take_note 记下，否则就忘了。**$desc$
WHERE key = 'fetch_url';

UPDATE pendingbot.tools SET model_description = $desc$记录一条对朋友真正有冲击力的笔记。平庸常识不要记。**这是把短期信息搬到长期记忆的唯一方式：本轮的搜索/抓取结果下一轮就被精简了，note 不会丢。**$desc$
WHERE key = 'take_note';

UPDATE pendingbot.tools SET model_description = $desc$当你判断已经探索得足够、可以收笔时调用——这是结束探索阶段、立刻进入写作的唯一方式。调用后这一轮就是探索的最后一轮，写作模型会基于你目前的笔记和访问过的链接直接出文。只决定"是否停止探索"，不决定"写不写"——觉得不值得写就别停。$desc$
WHERE key = 'stop_exploring';

ALTER TABLE pendingbot.tools
  ADD CONSTRAINT tools_native_model_description_chk CHECK (
    kind = 'mcp'
    OR (model_description IS NOT NULL AND btrim(model_description) <> '')
  );

COMMENT ON COLUMN pendingbot.tools.model_description IS
  'The model-facing tool description (function.description). For native '
  'tools this is the single source of truth — required, edited from the '
  'board Tools page. For MCP tools NULL means use the upstream server''s '
  'own description.';

COMMIT;
