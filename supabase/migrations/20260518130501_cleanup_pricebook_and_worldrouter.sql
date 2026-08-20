-- Routing-layer cleanup.
--
-- 1. Drop the unused cache-write price column from llm_model_aliases.
--    It was selected into the router's AliasJoinRow / RouteAlias but read
--    by nothing: computeCost never referenced it, and text billing reads
--    the AI-Gateway-reported cost rather than computing from the price
--    book. The other alias price columns (input/cached/output, audio_*)
--    stay.
--
-- 2. Remove the abandoned WorldRouter provider and its alias rows. It was
--    disabled at the AI Gateway cutover and never re-enabled. Historical
--    audit_log rows reference it via provider_id / model_alias_id; those
--    references are nulled (audit history is not retained) so the rows
--    can be deleted cleanly.

alter table pendingbot.llm_model_aliases
  drop column if exists cache_write_price;

update pendingbot.audit_log
  set model_alias_id = null
  where model_alias_id in (
    select a.id from pendingbot.llm_model_aliases a
    join pendingbot.llm_providers p on p.id = a.provider_id
    where p.slug = 'worldrouter'
  );

update pendingbot.audit_log
  set provider_id = null
  where provider_id in (
    select id from pendingbot.llm_providers where slug = 'worldrouter'
  );

delete from pendingbot.llm_model_aliases
  where provider_id in (
    select id from pendingbot.llm_providers where slug = 'worldrouter'
  );

delete from pendingbot.llm_providers where slug = 'worldrouter';
