-- Account-deletion cascade: bring the subject subtree current.
--
-- Root cause. `pendingbot.subjects.user_id -> auth.users ON DELETE CASCADE`
-- (added with the subject system on 2026-05-24) means deleting an auth user
-- cascade-deletes their *personal* subject (subjects.user_id = the user;
-- group subjects have user_id NULL and are untouched). But the subject's
-- child tables — all added across the T4.x PendingCrew / device-grant work
-- *after* 0052 — were left at ON DELETE NO ACTION. So the cascade hits a
-- wall and Studio "Delete user" / the GoTrue admin API /
-- finalize_account_deletion all fail with "Database error deleting user".
--
-- The wall seen in production: subject_device_grants.subject_id CASCADEs with
-- the subject while subject_device_login_challenges.issued_grant_id was
-- ON DELETE SET NULL. The convergent multi-path cascade (the grant deleted +
-- the same challenge's subject ref SET NULL in one statement) tripped
-- subject_device_login_challenges_issued_grant_fkey (SQLSTATE 23503).
--
-- 0052 already moved the pre-subject cleanup into a BEFORE DELETE trigger and
-- handled the simple post-0002 FKs with SET NULL ALTERs. This migration does
-- the same for the subject subtree: every NO ACTION / tangle-prone FK
-- reachable from the personal-subject deletion gets a deliberate action.
--
--   CASCADE  — the row is the user's own work; delete it with the account.
--   SET NULL — the row is shared / historical; keep it, just disown.
--
-- The full NO ACTION closure of the deletion (audited across the whole
-- pendingbot schema) is exactly: the 8 subjects-> children below, the two
-- temporary_group_members-> crew_sessions member pointers, and
-- skills.forked_from (a pre-existing self-FK edge case — another user's fork
-- of a deleted skill). conversations-> audit_log and the messages self-FKs
-- are already handled by the 0052 trigger, so they are intentionally absent.

BEGIN;

-- ── device login: a challenge dies with its grant (breaks the 23503 tangle) ─
ALTER TABLE pendingbot.subject_device_login_challenges
  DROP CONSTRAINT IF EXISTS subject_device_login_challenges_issued_grant_fkey;
ALTER TABLE pendingbot.subject_device_login_challenges
  ADD CONSTRAINT subject_device_login_challenges_issued_grant_fkey
    FOREIGN KEY (issued_grant_id)
    REFERENCES pendingbot.subject_device_grants(id) ON DELETE CASCADE;

-- ── the subject's own work artifacts → CASCADE with the subject ─────────────
ALTER TABLE pendingbot.crew_announcement_mentions
  DROP CONSTRAINT IF EXISTS crew_announcement_mentions_responsible_subject_id_fkey;
ALTER TABLE pendingbot.crew_announcement_mentions
  ADD CONSTRAINT crew_announcement_mentions_responsible_subject_id_fkey
    FOREIGN KEY (responsible_subject_id)
    REFERENCES pendingbot.subjects(id) ON DELETE CASCADE;

ALTER TABLE pendingbot.crew_announcements
  DROP CONSTRAINT IF EXISTS crew_announcements_responsible_subject_id_fkey;
ALTER TABLE pendingbot.crew_announcements
  ADD CONSTRAINT crew_announcements_responsible_subject_id_fkey
    FOREIGN KEY (responsible_subject_id)
    REFERENCES pendingbot.subjects(id) ON DELETE CASCADE;

ALTER TABLE pendingbot.crew_sessions
  DROP CONSTRAINT IF EXISTS crew_sessions_responsible_subject_id_fkey;
ALTER TABLE pendingbot.crew_sessions
  ADD CONSTRAINT crew_sessions_responsible_subject_id_fkey
    FOREIGN KEY (responsible_subject_id)
    REFERENCES pendingbot.subjects(id) ON DELETE CASCADE;

ALTER TABLE pendingbot.human_help_requests
  DROP CONSTRAINT IF EXISTS human_help_requests_responsible_subject_id_fkey;
ALTER TABLE pendingbot.human_help_requests
  ADD CONSTRAINT human_help_requests_responsible_subject_id_fkey
    FOREIGN KEY (responsible_subject_id)
    REFERENCES pendingbot.subjects(id) ON DELETE CASCADE;

ALTER TABLE pendingbot.permission_requests
  DROP CONSTRAINT IF EXISTS permission_requests_responsible_subject_id_fkey;
ALTER TABLE pendingbot.permission_requests
  ADD CONSTRAINT permission_requests_responsible_subject_id_fkey
    FOREIGN KEY (responsible_subject_id)
    REFERENCES pendingbot.subjects(id) ON DELETE CASCADE;

ALTER TABLE pendingbot.runner_leases
  DROP CONSTRAINT IF EXISTS runner_leases_responsible_subject_id_fkey;
ALTER TABLE pendingbot.runner_leases
  ADD CONSTRAINT runner_leases_responsible_subject_id_fkey
    FOREIGN KEY (responsible_subject_id)
    REFERENCES pendingbot.subjects(id) ON DELETE CASCADE;

ALTER TABLE pendingbot.session_mailbox_items
  DROP CONSTRAINT IF EXISTS session_mailbox_items_responsible_subject_id_fkey;
ALTER TABLE pendingbot.session_mailbox_items
  ADD CONSTRAINT session_mailbox_items_responsible_subject_id_fkey
    FOREIGN KEY (responsible_subject_id)
    REFERENCES pendingbot.subjects(id) ON DELETE CASCADE;

-- ── shared / group data → survive the responsible user, just disown ────────
-- A temporary group can outlive the member who was its billing-responsible
-- subject (other members are still in it), mirroring 0052's treatment of
-- conversation_group_meta.created_by. responsible_subject_id is NOT NULL
-- today, so make it nullable first.
ALTER TABLE pendingbot.temporary_group_meta
  ALTER COLUMN responsible_subject_id DROP NOT NULL;
ALTER TABLE pendingbot.temporary_group_meta
  DROP CONSTRAINT IF EXISTS temporary_group_meta_responsible_subject_id_fkey;
ALTER TABLE pendingbot.temporary_group_meta
  ADD CONSTRAINT temporary_group_meta_responsible_subject_id_fkey
    FOREIGN KEY (responsible_subject_id)
    REFERENCES pendingbot.subjects(id) ON DELETE SET NULL;

-- crew_sessions member pointers: deleting a user CASCADEs their
-- temporary_group_members rows (members.user_id -> auth.users CASCADE). A crew
-- session that referenced one keeps its own responsible_subject ownership and
-- just loses the member pointer. initiating_member_id is NOT NULL today.
ALTER TABLE pendingbot.crew_sessions
  ALTER COLUMN initiating_member_id DROP NOT NULL;
ALTER TABLE pendingbot.crew_sessions
  DROP CONSTRAINT IF EXISTS crew_sessions_initiating_member_id_fkey;
ALTER TABLE pendingbot.crew_sessions
  ADD CONSTRAINT crew_sessions_initiating_member_id_fkey
    FOREIGN KEY (initiating_member_id)
    REFERENCES pendingbot.temporary_group_members(id) ON DELETE SET NULL;

ALTER TABLE pendingbot.crew_sessions
  DROP CONSTRAINT IF EXISTS crew_sessions_assigned_to_member_id_fkey;
ALTER TABLE pendingbot.crew_sessions
  ADD CONSTRAINT crew_sessions_assigned_to_member_id_fkey
    FOREIGN KEY (assigned_to_member_id)
    REFERENCES pendingbot.temporary_group_members(id) ON DELETE SET NULL;

-- skills fork lineage: a fork of a deleted skill keeps existing, loses its
-- ancestry pointer. Pre-existing NO ACTION self-FK, unrelated to subjects but
-- in the deletion closure when another user forked a skill being deleted.
ALTER TABLE pendingbot.skills
  DROP CONSTRAINT IF EXISTS skills_forked_from_fkey;
ALTER TABLE pendingbot.skills
  ADD CONSTRAINT skills_forked_from_fkey
    FOREIGN KEY (forked_from)
    REFERENCES pendingbot.skills(id) ON DELETE SET NULL;

COMMIT;
