-- Rename scroll-* prompt IDs to envelope-* in pendingbot.i18n_prompts.
-- The seed (20260511070321) inserted rows keyed by `scroll`,
-- `scroll-injected`, `scroll-write`, `scroll-collaborator`; the edge
-- prompt-loader has been retargeted to envelope-* names + envelope*.md
-- bundled files in the same commit. Without this UPDATE the loader's
-- DB-override cache misses on the new names and silently falls back to
-- the (now renamed) bundled file — fine in practice but the override
-- mechanism is dead until the Board re-saves each prompt. This patches
-- the in-flight rows over to the new identifiers.

BEGIN;

UPDATE pendingbot.i18n_prompts SET name = 'envelope'              WHERE name = 'scroll';
UPDATE pendingbot.i18n_prompts SET name = 'envelope-injected'     WHERE name = 'scroll-injected';
UPDATE pendingbot.i18n_prompts SET name = 'envelope-write'        WHERE name = 'scroll-write';
UPDATE pendingbot.i18n_prompts SET name = 'envelope-collaborator' WHERE name = 'scroll-collaborator';

COMMIT;
