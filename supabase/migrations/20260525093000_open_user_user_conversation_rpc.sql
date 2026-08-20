-- Atomic user_user conversation open.
--
-- The Edge route used to "find shared participants, then insert conversation
-- and participants" in separate service-role statements. Under concurrent
-- taps from two devices that can create duplicate user_user conversations for
-- the same unordered pair. This RPC takes a transaction-scoped advisory lock
-- on the canonical pair and performs the find-or-create in one database
-- transaction under auth.uid().

CREATE OR REPLACE FUNCTION pendingbot.open_user_user_conv(p_other_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pendingbot, public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_pair_a uuid;
  v_pair_b uuid;
  v_conversation_id uuid;
  v_created boolean := false;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'auth required';
  END IF;

  IF p_other_user_id IS NULL OR p_other_user_id = v_user_id THEN
    RAISE EXCEPTION 'cannot open self user_user conversation';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM pendingbot.user_contacts uc
     WHERE uc.user_id = v_user_id
       AND uc.contact_user_id = p_other_user_id
  ) THEN
    RAISE EXCEPTION 'not contacts';
  END IF;

  v_pair_a := LEAST(v_user_id, p_other_user_id);
  v_pair_b := GREATEST(v_user_id, p_other_user_id);

  PERFORM pg_advisory_xact_lock(
    hashtextextended(v_pair_a::text || ':' || v_pair_b::text, 0)
  );

  SELECT cp1.conversation_id
    INTO v_conversation_id
    FROM pendingbot.conversation_participants cp1
    JOIN pendingbot.conversation_participants cp2
      ON cp2.conversation_id = cp1.conversation_id
    JOIN pendingbot.conversations c
      ON c.id = cp1.conversation_id
   WHERE c.conversation_type = 'user_user'
     AND cp1.participant_type = 'user'
     AND cp1.participant_id = v_user_id
     AND cp2.participant_type = 'user'
     AND cp2.participant_id = p_other_user_id
   ORDER BY c.created_at ASC
   LIMIT 1;

  IF v_conversation_id IS NULL THEN
    INSERT INTO pendingbot.conversations (
      conversation_type,
      feature,
      user_id,
      title
    )
    VALUES (
      'user_user',
      'message',
      v_user_id,
      NULL
    )
    RETURNING id INTO v_conversation_id;

    INSERT INTO pendingbot.conversation_participants (
      conversation_id,
      participant_type,
      participant_id,
      role
    )
    VALUES
      (v_conversation_id, 'user', v_user_id, 'owner'),
      (v_conversation_id, 'user', p_other_user_id, 'member');

    v_created := true;
  END IF;

  RETURN jsonb_build_object(
    'conversationId', v_conversation_id,
    'created', v_created
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION pendingbot.open_user_user_conv(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION pendingbot.open_user_user_conv(uuid)
  TO authenticated, service_role;
