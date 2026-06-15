-- Drop the crew `tag` column. The only live RPC that wrote it
-- (create_crew_with_captain) was rewritten in File 2 to no longer reference it,
-- so this drop is safe. The partial index temporary_group_meta_tag_idx cascades
-- with the column.
set search_path = pendingbot, public;
alter table pendingbot.temporary_group_meta drop column if exists tag;
