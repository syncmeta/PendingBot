# Migration number registry

**Last assigned: `0063`**

This file is the canonical record of every supabase migration number that has been
claimed in this repo, including ones still unmerged on feature branches. It exists
because we routinely run multiple Claude Code sessions in parallel worktrees, and
each session only sees `main` — without a shared registry, two sessions both pick
"max+1" and collide on the same number.

## Protocol — read this before creating a new migration file

1. **Read the `Last assigned` line above** and the `Reserved (unmerged branches)`
   section below. Your number is `last_assigned + 1`, unless a higher number is
   already reserved — then go higher than the highest reserved.
2. **Defense in depth — also run:**
   ```
   git fetch --quiet
   git log --all --name-only --pretty=format: -- 'supabase/migrations/*.sql' \
     | grep -oE '00[0-9]+' | sort -u | tail -5
   ```
   If you see a number on a remote branch that isn't listed in `Reserved` below,
   somebody else's session pushed without updating the registry — pick higher
   than that, and add their entry to `Reserved` as part of your commit.
3. **Reserve your number in this file _in the same commit_ as the migration**:
   - Bump the `Last assigned` line at the top.
   - Append your row to the `History` table.
   - If your branch is unmerged when you commit, also add it to `Reserved`. Remove
     that row when the branch lands on `main`.
4. **Auto-push** is on for non-main branches per the user's workflow, so once you
   push, parallel sessions can see your reservation via `git fetch`.

If two sessions still collide despite this (e.g. both ran step 1 before either
pushed), the loser renumbers on their branch with a `chore(db): renumber 00NN →
00MM` commit before merging — same recipe we've used historically.

## Reserved (unmerged branches)

| Number | Filename | Branch | Notes |
|--------|----------|--------|-------|
| _(none)_ | | | |

## History

| Number | Filename |
|--------|----------|
| 0001 | `0001_init.sql` |
| 0002 | `0002_bot_visibility.sql` |
| 0003 | `0003_bot_invites_add.sql` |
| 0004 | `0004_list_bot_invitees.sql` |
| 0020 | `0020_scroll.sql` |
| 0021 | `0021_drop_deprecated_features.sql` |
| 0022 | `0022_fix_bots_rls_recursion.sql` |
| 0023 | `0023_refresh_preset_bots.sql` |
| 0024 | `0024_preset_dialogue_ordering.sql` |
| 0025 | `0025_dolor_preset_wip_stub.sql` |
| 0026 | `0026_skills_validation_and_versions.sql` |
| 0027 | `0027_bot_sandbox_sessions.sql` |
| 0028 | `0028_seed_code_runner_skill.sql` |
| 0029 | `0029_open_user_bot_conv_allow_preset_private.sql` |
| 0030 | `0030_admin_provider_routing.sql` |
| 0031 | `0031_task_routing_rules.sql` |
| 0032 | `0032_seed_worldrouter_provider.sql` |
| 0033 | `0033_billing.sql` |
| 0034 | `0034_billing_admin_rpcs.sql` |
| 0035 | `0035_message_citations.sql` |
| 0036 | `0036_pin_title_to_gemma.sql` |
| 0037 | `0037_bot_code_exec_requests.sql` |
| 0038 | `0038_conversation_provider_override.sql` |
| 0039 | `0039_audit_log_est_tokens.sql` |
| 0040 | `0040_signup_bonus_3500.sql` |
| 0041 | `0041_envelopes_settings.sql` |
| 0042 | `0042_account_deletion_sentiment.sql` |
| 0043 | `0043_group_chat_schema.sql` |
| 0044 | `0044_unread_trigger_definer.sql` |
| 0045 | `0045_group_chat_rpcs.sql` |
| 0046 | `0046_friend_requests.sql` |
| 0047 | `0047_drop_review_feature.sql` |
| 0048 | `0048_group_member_cap_30.sql` |
| 0049 | `0049_accept_friend_request_user_param.sql` |
| 0050 | `0050_disposable_email_block.sql` |
| 0051 | `0051_account_deletion_cooldown.sql` |
| 0052 | `0052_auth_delete_user_trigger.sql` |
| 0053 | `0053_lint_fix_views_and_disposable_rls.sql` |
| 0054 | `0054_start_user_bot_turn.sql` |
| 0055 | `0055_self_chat_per_user_bot.sql` |
| 0056 | `0056_seed_example_letter.sql` |
| 0057 | `0057_preset_id_handle.sql` |
| 0058 | `0058_conv_model_override.sql` |
| 0059 | `0059_skill_subscriptions_nullable_conv.sql` |
| 0060 | `0060_publish_group_continue_requests.sql` |
| 0061 | `0061_friend_request_remark.sql` |
| 0062 | `0062_backfill_user_avatar_path.sql` |
| 0063 | `0063_attachments_rls_avatar_visibility.sql` |
