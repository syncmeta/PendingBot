-- The creator keeps full settings control over a bot even after it goes
-- public. Previously a public bot froze everything except its visibility
-- level; now only the private→public direction is one-way — the creator
-- can still rename it, switch models, tweak config, toggle voice, etc.
--
-- Also: voice calls now default ON for new bots (was OFF).

BEGIN;

-- ── Voice calls default on ───────────────────────────────────────────
ALTER TABLE pendingbot.bots
  ALTER COLUMN voice_call_enabled SET DEFAULT true;

-- ── Trigger: public bots stay editable by their creator ──────────────
-- Drops the column freeze (slug / display_name / model_id / output_mode
-- / is_active / config / creator_id). The only remaining guard: a public
-- bot cannot revert to private — publishing is still one-way.
CREATE OR REPLACE FUNCTION pendingbot.bots_guard_public_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.creator_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF OLD.visibility <> 'private' AND NEW.visibility = 'private' THEN
    RAISE EXCEPTION '公有机器人不能转回私有';
  END IF;

  RETURN NEW;
END
$$;

COMMIT;
