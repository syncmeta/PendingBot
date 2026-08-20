-- Arbitrary-file attachments: keep the user-facing filename so non-image
-- attachments can render a "icon + name" chip and the prompt builder can
-- label files in the attachment inventory. Images never needed it (they
-- render from bytes); files do. Nullable — legacy image rows have none,
-- and R2 customMetadata.originalName is not a queryable source.
alter table pendingbot.attachments
  add column if not exists filename text;
