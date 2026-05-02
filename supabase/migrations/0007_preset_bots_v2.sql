-- Replace the v1 preset roster (小绿 / 老周 / 阿榕 / 简) with eight
-- "Lorem ipsum"-named bots, each on a different OpenRouter model.
-- Names match the first eight words of the canonical Lorem ipsum:
--   Lorem · ipsum · dolor · sit · amet · consectetur · adipiscing · elit
-- Capitalized exactly as the user specified (Lorem caps, the rest lower).
--
-- Old preset bots are deactivated rather than deleted, so any user who
-- already chatted with them keeps the history readable. New conversations
-- to the deactivated bots never get a reply (routes/messages.ts bails on
-- bot.is_active=false).

update pendingbot.bots
   set is_active = false
 where slug in ('xiaolu', 'lao-zhou', 'arong', 'jian');

insert into pendingbot.bots (slug, display_name, model_id) values
  ('lorem',       'Lorem',       'anthropic/claude-opus-latest'),
  ('ipsum',       'ipsum',       'deepseek/deepseek-v4-pro'),
  ('dolor',       'dolor',       'x-ai/grok-4.3'),
  ('sit',         'sit',         'moonshotai/kimi-latest'),
  ('amet',        'amet',        'z-ai/glm-5.1'),
  ('consectetur', 'consectetur', 'openai/gpt-5.4'),
  ('adipiscing',  'adipiscing',  'google/gemini-flash-latest'),
  ('elit',        'elit',        'minimax/minimax-m2.7')
on conflict (slug) do update
  set display_name = excluded.display_name,
      model_id    = excluded.model_id,
      is_active   = true;

-- Re-bootstrap every existing user so the eight new bots show up as
-- friend conversations. bootstrap_user_id is idempotent — it skips bots
-- the user already has a conv with, so old preset convs aren't touched.
do $$
declare u record;
begin
  for u in select id, email, raw_user_meta_data from auth.users loop
    perform pendingbot.bootstrap_user_id(u.id, u.email, u.raw_user_meta_data);
  end loop;
end $$;
