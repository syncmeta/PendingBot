-- friend_requests — gate user_user messaging behind explicit approval.
--
-- Until now /v1/contacts/add wrote symmetric user_contacts rows directly,
-- so anyone with a handle code or email could open a chat with that
-- person without the recipient ever seeing it as a request. We want a
-- two-step flow: A sends a request, B accepts before the chat materialises.
--
-- Layout: a single table with status ∈ {pending, accepted, declined,
-- cancelled}. `accepted` is the only terminal state that actually adds
-- contacts; the other terminal states keep the row for audit so a
-- recipient who declined doesn't get re-spammed (the unique-index below
-- only blocks duplicates while pending, so a declined → new request is
-- still possible — that's intentional, can be tightened later if abuse
-- emerges).
--
-- Writes go through the worker with service-role; RLS only exposes SELECT
-- to the two parties. Acceptance side-effects (writing both user_contacts
-- rows + flipping status) are bundled in pendingbot.accept_friend_request
-- so iOS can call one RPC instead of needing two trips.

CREATE TABLE pendingbot.friend_requests (
    id uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    from_user_id uuid NOT NULL,
    to_user_id uuid NOT NULL,
    status text DEFAULT 'pending' NOT NULL,
    -- Optional intro message the sender attaches ("hey, met you at X").
    -- Capped at 500 chars at the worker layer; column is plain text so
    -- a future schema change isn't blocked by a check constraint here.
    message text,
    -- Audit: which discovery method got us here. via_handle_id wins
    -- when the sender added by handle code (incl. QR scan); via_email
    -- carries the looked-up email otherwise. Either or neither may be set.
    via_handle_id uuid,
    via_email text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    responded_at timestamp with time zone,
    CONSTRAINT friend_requests_pkey PRIMARY KEY (id),
    CONSTRAINT friend_requests_status_check
        CHECK (status IN ('pending', 'accepted', 'declined', 'cancelled')),
    CONSTRAINT friend_requests_self_check CHECK (from_user_id <> to_user_id),
    CONSTRAINT friend_requests_from_fk
        FOREIGN KEY (from_user_id) REFERENCES auth.users(id) ON DELETE CASCADE,
    CONSTRAINT friend_requests_to_fk
        FOREIGN KEY (to_user_id) REFERENCES auth.users(id) ON DELETE CASCADE,
    CONSTRAINT friend_requests_via_handle_fk
        FOREIGN KEY (via_handle_id) REFERENCES pendingbot.user_handles(id) ON DELETE SET NULL
);

ALTER TABLE pendingbot.friend_requests OWNER TO postgres;

-- One pending request at a time per (sender, recipient) pair. Earlier
-- declined / cancelled rows stay around for audit.
CREATE UNIQUE INDEX friend_requests_one_pending_per_pair
    ON pendingbot.friend_requests (from_user_id, to_user_id)
    WHERE status = 'pending';

-- Inbox query — pending incoming, newest first.
CREATE INDEX idx_friend_requests_incoming_pending
    ON pendingbot.friend_requests (to_user_id, created_at DESC)
    WHERE status = 'pending';

-- Outgoing list — used by iOS to surface "you've already sent this person
-- a request" feedback without a separate count query.
CREATE INDEX idx_friend_requests_outgoing
    ON pendingbot.friend_requests (from_user_id, created_at DESC);

ALTER TABLE pendingbot.friend_requests ENABLE ROW LEVEL SECURITY;

-- Both parties can see their own outgoing/incoming requests. Writes are
-- worker-only (service-role bypasses RLS), so no INSERT/UPDATE/DELETE
-- policy is exposed to the authenticated role.
CREATE POLICY friend_requests_party_read
    ON pendingbot.friend_requests
    FOR SELECT
    USING (from_user_id = auth.uid() OR to_user_id = auth.uid());

GRANT SELECT ON TABLE pendingbot.friend_requests TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.friend_requests TO service_role;

-- Acceptance: flip status + write the two user_contacts rows in one shot.
-- SECURITY DEFINER so the function (owned by postgres) can write user_contacts
-- on behalf of the *sender* without tripping that table's RLS — there's no
-- "the recipient created your contacts row for you" path expressible via
-- the user-scoped contacts_self_* policies.
CREATE OR REPLACE FUNCTION pendingbot.accept_friend_request(p_request_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, pg_temp
AS $$
DECLARE
    me uuid := auth.uid();
    rq record;
BEGIN
    IF me IS NULL THEN
        RAISE EXCEPTION 'no auth' USING ERRCODE = '28000';
    END IF;

    SELECT * INTO rq FROM pendingbot.friend_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'request not found' USING ERRCODE = 'P0002';
    END IF;
    IF rq.to_user_id <> me THEN
        RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
    END IF;
    IF rq.status <> 'pending' THEN
        RAISE EXCEPTION 'request not pending: %', rq.status USING ERRCODE = 'P0001';
    END IF;

    UPDATE pendingbot.friend_requests
    SET status = 'accepted',
        responded_at = now(),
        updated_at = now()
    WHERE id = p_request_id;

    INSERT INTO pendingbot.user_contacts (user_id, contact_user_id, added_via_handle_id)
    VALUES
        (rq.from_user_id, rq.to_user_id, rq.via_handle_id),
        (rq.to_user_id,   rq.from_user_id, rq.via_handle_id)
    ON CONFLICT (user_id, contact_user_id) DO NOTHING;
END;
$$;

REVOKE ALL ON FUNCTION pendingbot.accept_friend_request(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.accept_friend_request(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION pendingbot.accept_friend_request(uuid) TO service_role;
