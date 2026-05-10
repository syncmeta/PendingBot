-- 0064_attachments_vision_summary.sql
--
-- Vision/multimodal infrastructure. Three things:
--
-- 1. attachments now carries a model-generated summary + tags + which model
--    produced them. This lets us show the model "this conversation contains
--    these images: [id=abc, summary=..., tags=[...]]" in context without
--    re-uploading the image bytes every turn. The model can re-read an
--    image on demand via the read_attachment tool.
--
-- 2. conversations.vision_model_override pins a specific vision-capable
--    model for image reads in this conv. NULL = "auto": use the main
--    model if it has vision, else fall back to the global default
--    (currently moonshotai/kimi-latest, hardcoded in edge/llm/vision.ts).
--
-- 3. llm_models.capabilities already exists as jsonb (0030); we use the
--    `vision` key. This migration seeds known vision-capable model slugs
--    so the edge worker can detect "main model has vision" without admin
--    curation. Models added later get the bit ticked in the admin panel.

-- ----------------------------------------------------------------
-- 1. attachments: summary columns
-- ----------------------------------------------------------------
ALTER TABLE pendingbot.attachments
  ADD COLUMN summary text,
  ADD COLUMN tags text[] NOT NULL DEFAULT '{}',
  ADD COLUMN vision_model text,
  ADD COLUMN summary_status text NOT NULL DEFAULT 'pending',
  ADD COLUMN summary_error text,
  ADD COLUMN summarized_at timestamp with time zone;

ALTER TABLE pendingbot.attachments
  ADD CONSTRAINT attachments_summary_status_chk
  CHECK (summary_status IN ('pending', 'done', 'failed', 'skipped'));

-- Cheap filter for the summarizer worker / sweeps: "find attachments that
-- still need a summary". Partial index keeps it tiny — most rows are 'done'.
CREATE INDEX idx_attachments_summary_pending
  ON pendingbot.attachments(created_at)
  WHERE summary_status = 'pending';

-- ----------------------------------------------------------------
-- 2. conversations: vision model override
-- ----------------------------------------------------------------
ALTER TABLE pendingbot.conversations
  ADD COLUMN vision_model_override text;

COMMENT ON COLUMN pendingbot.conversations.vision_model_override IS
  'Per-conv vision model pin. NULL = auto (use main model if vision-capable, '
  'else fall back to DEFAULT_VISION_MODEL in edge/llm/vision.ts). When set, '
  'must be a slug whose llm_models row has capabilities.vision = true.';

-- ----------------------------------------------------------------
-- 3. Seed vision capability on known multimodal models
-- ----------------------------------------------------------------
-- Idempotent: only updates rows that exist. Any not yet registered will
-- get ticked when the admin adds them via the board UI.
UPDATE pendingbot.llm_models
   SET capabilities = capabilities || jsonb_build_object('vision', true),
       updated_at = now()
 WHERE slug IN (
   'moonshotai/kimi-latest',
   'anthropic/claude-opus-4.5',
   'anthropic/claude-opus-4.6',
   'anthropic/claude-opus-4.7',
   'anthropic/claude-sonnet-4',
   'anthropic/claude-sonnet-4.5',
   'anthropic/claude-sonnet-4.6',
   'openai/gpt-4o',
   'openai/gpt-4o-mini',
   'openai/gpt-4.1',
   'openai/gpt-4.1-mini',
   'openai/gpt-5',
   'google/gemini-2.5-flash',
   'google/gemini-2.5-flash-lite',
   'google/gemini-2.5-pro',
   'google/gemini-3-flash-preview',
   'google/gemini-3-pro-preview',
   'xai/grok-4',
   'xai/grok-4.1-fast'
 );
