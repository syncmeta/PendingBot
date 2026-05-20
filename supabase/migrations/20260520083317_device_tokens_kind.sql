-- Tag device_tokens rows with whether they hold a regular APNs token or a
-- PushKit/VoIP token. Each iOS install now contributes two rows: one
-- `apns` token used for messages + non-call notifications, and one `voip`
-- token used exclusively for voice_ring (CallKit incoming) fan-out. Apple
-- requires a distinct topic + push-type for VoIP delivery, so we can't
-- multiplex on one row.

ALTER TABLE pendingbot.device_tokens
    ADD COLUMN kind text NOT NULL DEFAULT 'apns'
        CHECK (kind IN ('apns', 'voip'));

-- The existing UNIQUE (user_id, token) already prevents the same hex
-- string from appearing twice for one user. APNs + VoIP tokens are
-- different hex strings (Apple mints them via separate registries) so
-- the existing constraint is enough — no need for a (user_id, kind)
-- partial index.
COMMENT ON COLUMN pendingbot.device_tokens.kind IS
    'apns = standard APNs token (alert / background pushes); voip = PushKit VoIP token used for CallKit-incoming voice rings.';
