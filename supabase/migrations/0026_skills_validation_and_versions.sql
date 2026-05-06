-- Tighten skills frontmatter shape, cap body length, and add an append-only
-- version history table populated by trigger on every UPDATE.
--
-- Bounds chosen to fit the seeded Anthropic presets (skill-creator.md is
-- ~33 KiB; doc-coauthoring description is ~480 chars):
--   body_md         ≤ 64 KiB
--   frontmatter.name        kebab-case, 1..80 chars (REQUIRED)
--   frontmatter.description optional string, ≤ 2000 chars
--   frontmatter.allowed_tools optional jsonb array  (used by the bot
--                            agent loop to gate sensitive tools like
--                            execute_code on a per-skill basis)
--   other frontmatter keys (license, model, source, ...) pass through.

BEGIN;

ALTER TABLE pendingbot.skills
  ADD CONSTRAINT skills_body_max_size CHECK (length(body_md) <= 65536);

ALTER TABLE pendingbot.skills
  ADD CONSTRAINT skills_frontmatter_shape CHECK (
    jsonb_typeof(frontmatter) = 'object'
    AND jsonb_typeof(frontmatter -> 'name') = 'string'
    AND char_length(frontmatter ->> 'name') BETWEEN 1 AND 80
    AND frontmatter ->> 'name' ~ '^[a-z0-9]+(-[a-z0-9]+)*$'
    AND (NOT frontmatter ? 'description'
         OR (jsonb_typeof(frontmatter -> 'description') = 'string'
             AND char_length(frontmatter ->> 'description') <= 2000))
    AND (NOT frontmatter ? 'allowed_tools'
         OR jsonb_typeof(frontmatter -> 'allowed_tools') = 'array')
  );


-- ── Version history ─────────────────────────────────────────────────────────
-- skill_versions = append-only log of (frontmatter, body_md) snapshots taken
-- BEFORE each meaningful UPDATE. The skills row itself is "head"; this table
-- is the trail. CASCADE on skill delete so we don't accumulate orphans.
CREATE TABLE pendingbot.skill_versions (
    id uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    skill_id uuid NOT NULL,
    frontmatter jsonb NOT NULL,
    body_md text NOT NULL,
    edited_by uuid,                   -- auth.uid() at edit time; null = service-role / system
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT skill_versions_pkey PRIMARY KEY (id),
    CONSTRAINT skill_versions_skill_id_fkey
      FOREIGN KEY (skill_id) REFERENCES pendingbot.skills(id) ON DELETE CASCADE,
    CONSTRAINT skill_versions_edited_by_fkey
      FOREIGN KEY (edited_by) REFERENCES auth.users(id) ON DELETE SET NULL
);
ALTER TABLE pendingbot.skill_versions OWNER TO postgres;

CREATE INDEX idx_skill_versions_skill_time
  ON pendingbot.skill_versions(skill_id, created_at DESC);

ALTER TABLE pendingbot.skill_versions ENABLE ROW LEVEL SECURITY;

-- Same read rules as the parent skill: owner reads own; public skills are
-- readable by anyone. Bot-private rows (bot_id IS NOT NULL) stay hidden.
CREATE POLICY skill_versions_read ON pendingbot.skill_versions
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM pendingbot.skills s
      WHERE s.id = skill_versions.skill_id
        AND (s.owner_id = auth.uid()
             OR (s.bot_id IS NULL AND s.visibility = 'public'))
    )
  );

GRANT SELECT ON TABLE pendingbot.skill_versions TO authenticated;
GRANT SELECT ON TABLE pendingbot.skill_versions TO anon;
GRANT SELECT, INSERT, DELETE, UPDATE ON TABLE pendingbot.skill_versions TO service_role;


-- ── Snapshot trigger ───────────────────────────────────────────────────────
-- Snapshots OLD into skill_versions before UPDATEs that actually change
-- frontmatter or body. SECURITY DEFINER so the trigger can write into the
-- table even when the editor's role lacks INSERT (RLS would otherwise block).
CREATE OR REPLACE FUNCTION pendingbot.snapshot_skill_version()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pendingbot', 'public', 'auth'
AS $$
BEGIN
  INSERT INTO pendingbot.skill_versions (skill_id, frontmatter, body_md, edited_by)
  VALUES (OLD.id, OLD.frontmatter, OLD.body_md, auth.uid());
  RETURN NEW;
END;
$$;
ALTER FUNCTION pendingbot.snapshot_skill_version() OWNER TO postgres;
REVOKE ALL ON FUNCTION pendingbot.snapshot_skill_version() FROM PUBLIC;

CREATE TRIGGER skills_snapshot_on_update
  BEFORE UPDATE OF frontmatter, body_md ON pendingbot.skills
  FOR EACH ROW
  WHEN (OLD.frontmatter IS DISTINCT FROM NEW.frontmatter
        OR OLD.body_md IS DISTINCT FROM NEW.body_md)
  EXECUTE FUNCTION pendingbot.snapshot_skill_version();

COMMIT;
