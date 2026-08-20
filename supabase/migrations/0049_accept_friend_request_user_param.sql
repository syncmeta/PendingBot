-- 0047: accept_friend_request — caller passes the acting user id.
--
-- 0046 read auth.uid() inside the function, but the only caller is the
-- edge worker via service_role — which has no auth.uid() (the
-- service_role JWT carries no `sub` claim). Every accept call therefore
-- raised 'no auth', the worker turned that into a 500, and iOS surfaced
-- it as "处理好友申请失败 / NSURLErrorDomain -1011" with no usable detail.
--
-- Fix: take the acting user id as a parameter. The worker has already
-- authenticated the JWT and knows who's calling, so the function trusts
-- that param. The recipient/status checks under FOR UPDATE still run, so
-- a forged p_user_id can't accept someone else's request.
--
-- Argument-list change ⇒ DROP and recreate (Postgres treats overloads as
-- distinct functions). Removing the GRANT to `authenticated` at the same
-- time: nobody calls this directly from a user JWT — iOS goes through
-- the worker — so the smaller grant surface is correct.

DROP FUNCTION IF EXISTS pendingbot.accept_friend_request(uuid);

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

    INSERT INTO pendingbot.user_contacts (user_id, contact_user_id, added_via_handle_id)
    VALUES
        (rq.from_user_id, rq.to_user_id, rq.via_handle_id),
        (rq.to_user_id,   rq.from_user_id, rq.via_handle_id)
    ON CONFLICT (user_id, contact_user_id) DO NOTHING;
END;
$$;

REVOKE ALL ON FUNCTION pendingbot.accept_friend_request(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pendingbot.accept_friend_request(uuid, uuid) TO service_role;
