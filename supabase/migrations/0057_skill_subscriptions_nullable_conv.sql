-- 0057_skill_subscriptions_nullable_conv — allow conversation_id IS NULL
-- to mean "global subscription" (applies in every conversation), matching
-- what iOS and edge already assume:
--   - iOS Skills tab toggles a row with conversation_id = NULL
--     (apps/ios/PendingBot/Features/Skills/SkillsView.swift)
--   - bot-reply.ts loads skills with
--     `conversation_id.eq.<id>,conversation_id.is.null`
--     (apps/edge/src/lib/bot-reply.ts)
--
-- Original schema in 0001 had conversation_id NOT NULL and as part of the
-- PK, which made the global toggle fail with:
--   null value in column "conversation_id" of relation
--   "skill_subscriptions" violates not-null constraint
--
-- Replacement uniqueness model — two partial unique indexes:
--   * one global row per (user_id, skill_id)
--   * one per-conversation row per (user_id, skill_id, conversation_id)

ALTER TABLE pendingbot.skill_subscriptions
  DROP CONSTRAINT skill_subscriptions_pkey;

ALTER TABLE pendingbot.skill_subscriptions
  ALTER COLUMN conversation_id DROP NOT NULL;

CREATE UNIQUE INDEX skill_subscriptions_user_skill_global_uq
  ON pendingbot.skill_subscriptions (user_id, skill_id)
  WHERE conversation_id IS NULL;

CREATE UNIQUE INDEX skill_subscriptions_user_skill_conv_uq
  ON pendingbot.skill_subscriptions (user_id, skill_id, conversation_id)
  WHERE conversation_id IS NOT NULL;
