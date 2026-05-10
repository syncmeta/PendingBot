-- friend_requests.remark_for_contact + accept_friend_request alias write.
--
-- New 加好友 page lets the sender attach a 备注 (alias) for the recipient at
-- request time. We store it on the request row so it survives until the
-- recipient accepts; on accept, the RPC copies it into user_contacts.alias
-- for the sender→recipient direction (the recipient can set their own
-- alias for the sender separately).
--
-- The reverse direction (recipient→sender) gets no alias here — only the
-- sender chose a remark; the recipient's view stays default until they
-- edit it themselves.

BEGIN;

ALTER TABLE pendingbot.friend_requests
    ADD COLUMN IF NOT EXISTS remark_for_contact text;

COMMENT ON COLUMN pendingbot.friend_requests.remark_for_contact IS
    'Optional alias the sender attaches at request time; on accept, copied into user_contacts.alias for the sender→recipient row.';

CREATE OR REPLACE FUNCTION pendingbot.accept_friend_request(
    p_request_id uuid,
    p_user_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, pg_temp
AS $$
DECLARE
    rq record;
BEGIN
    IF p_user_id IS NULL THEN
        RAISE EXCEPTION 'p_user_id required' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO rq FROM pendingbot.friend_requests WHERE id = p_request_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'request not found' USING ERRCODE = 'P0002';
    END IF;
    IF rq.to_user_id <> p_user_id THEN
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

    INSERT INTO pendingbot.user_contacts (user_id, contact_user_id, added_via_handle_id, alias)
    VALUES
        (rq.from_user_id, rq.to_user_id, rq.via_handle_id, rq.remark_for_contact),
        (rq.to_user_id,   rq.from_user_id, rq.via_handle_id, NULL)
    ON CONFLICT (user_id, contact_user_id) DO NOTHING;
END;
$$;

REVOKE ALL ON FUNCTION pendingbot.accept_friend_request(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.accept_friend_request(uuid, uuid) TO service_role;

COMMIT;
