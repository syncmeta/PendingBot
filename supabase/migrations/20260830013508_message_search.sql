-- Full-history message search for the Edge API.
--
-- The function is intentionally service-role only. Edge authenticates the
-- caller, passes the verified user id, and this query applies the same two
-- participant models used by the app (ordinary conversation participants and
-- temporary-group/crew access) before any searchable field is evaluated.
-- Keeping SECURITY INVOKER means there is no hidden privilege escalation: the
-- service role already owns the privileged read, while authenticated/anon can
-- never call this RPC directly with a forged p_user_id.

begin;

create extension if not exists unaccent with schema extensions;

create or replace function pendingbot.message_search_normalize(p_value text)
returns text
language sql
stable
security invoker
set search_path = ''
as $$
  select lower(
    normalize(
      extensions.unaccent(normalize(coalesce(p_value, ''), NFC)),
      NFKC
    )
  );
$$;

revoke execute on function pendingbot.message_search_normalize(text)
  from public, anon, authenticated;
grant execute on function pendingbot.message_search_normalize(text)
  to service_role;

create or replace function pendingbot.search_messages_for_user(
  p_user_id uuid,
  p_tokens text[],
  p_conversation_id uuid default null,
  p_after timestamptz default null,
  p_before timestamptz default null,
  p_cursor_created_at timestamptz default null,
  p_cursor_message_id uuid default null,
  p_limit integer default 51
)
returns table (
  conversation_id uuid,
  conversation_title text,
  conversation_type text,
  message_id uuid,
  message_seq bigint,
  text text,
  sender_name text,
  sender_id text,
  created_at timestamptz,
  attachment_metadata jsonb,
  matched_fields text[]
)
language sql
stable
security invoker
set search_path = ''
as $$
  with normalized_tokens as (
    select array_agg(pendingbot.message_search_normalize(token) order by ord) as tokens
      from unnest(coalesce(p_tokens, array[]::text[])) with ordinality as q(token, ord)
     where pendingbot.message_search_normalize(token) <> ''
  ),
  accessible_conversations as (
    select c.id, c.title, c.conversation_type
      from pendingbot.conversations c
     where p_user_id is not null
       and (p_conversation_id is null or c.id = p_conversation_id)
       and (
         exists (
           select 1
             from pendingbot.conversation_participants cp_access
            where cp_access.conversation_id = c.id
              and cp_access.participant_type = 'user'
              and cp_access.participant_id = p_user_id
         )
         or (
           c.conversation_type in ('temporary_group', 'crew')
           and pendingbot.can_view_temporary_group(c.id, p_user_id)
         )
       )
  ),
  candidates as (
    select
      c.id as conversation_id,
      coalesce(c.title, '未命名') as conversation_title,
      c.conversation_type,
      m.id as message_id,
      m.message_seq,
      coalesce(m.content, '') as text,
      coalesce(
        m.attachments ->> 'senderLabel',
        crew_sender.display_name,
        cp_sender.nickname,
        u.display_name,
        b.display_name,
        case
          when m.role in ('user', 'human') then '人类'
          when m.role = 'bot' then '机器人'
          when m.role = 'log' then 'Session'
          else m.role
        end
      ) as sender_name,
      coalesce(
        m.log_payload ->> 'session_id',
        m.user_id::text,
        m.sender_bot_id::text
      ) as sender_id,
      m.created_at,
      coalesce(att.metadata, '[]'::jsonb) as attachment_metadata,
      pendingbot.message_search_normalize(coalesce(m.content, '')) as text_haystack,
      pendingbot.message_search_normalize(concat_ws(
        E'\n',
        coalesce(
          m.attachments ->> 'senderLabel',
          crew_sender.display_name,
          cp_sender.nickname,
          u.display_name,
          b.display_name,
          case
            when m.role in ('user', 'human') then '人类'
            when m.role = 'bot' then '机器人'
            when m.role = 'log' then 'Session'
            else m.role
          end
        ),
        coalesce(m.log_payload ->> 'session_id', m.user_id::text, m.sender_bot_id::text)
      )) as sender_haystack,
      pendingbot.message_search_normalize(coalesce(att.search_text, '')) as attachment_haystack,
      pendingbot.message_search_normalize(
        to_char(m.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
      ) as time_haystack
    from accessible_conversations c
    join pendingbot.messages m on m.conversation_id = c.id
    left join pendingbot.users u on u.id = m.user_id
    left join pendingbot.bots b on b.id = m.sender_bot_id
    left join pendingbot.conversation_participants cp_sender
      on cp_sender.conversation_id = m.conversation_id
     and (
       (m.user_id is not null
        and cp_sender.participant_type = 'user'
        and cp_sender.participant_id = m.user_id)
       or (m.sender_bot_id is not null
           and cp_sender.participant_type = 'bot'
           and cp_sender.participant_id = m.sender_bot_id)
     )
    left join lateral (
      select member.display_name
        from pendingbot.temporary_group_members member
       where member.conversation_id = m.conversation_id
         and member.status = 'active'
         and (
           (m.user_id is not null and member.user_id = m.user_id)
           or (m.sender_bot_id is not null and member.bot_id = m.sender_bot_id)
           or (
             m.log_payload ->> 'session_id' is not null
             and member.code_session_id::text = m.log_payload ->> 'session_id'
           )
         )
       order by
         case
           when m.log_payload ->> 'session_id' is not null
             and member.code_session_id::text = m.log_payload ->> 'session_id' then 0
           when m.user_id is not null and member.user_id = m.user_id then 1
           else 2
         end,
         member.created_at desc,
         member.id
       limit 1
    ) crew_sender on true
    left join lateral (
      select
        jsonb_agg(
          jsonb_build_object(
            'id', a.id,
            'filename', a.filename,
            'mimeType', a.mime_type
          ) order by refs.ord
        ) as metadata,
        string_agg(concat_ws(E'\n', a.filename, a.mime_type), E'\n' order by refs.ord)
          as search_text
        from jsonb_array_elements_text(
          case
            when jsonb_typeof(m.attachments -> 'ids') = 'array'
              then m.attachments -> 'ids'
            else '[]'::jsonb
          end
        ) with ordinality refs(id, ord)
        join pendingbot.attachments a on a.id::text = refs.id
    ) att on true
   where m.message_seq is not null
     and m.status not in ('deleted', 'replaced')
     and coalesce(m.metadata ->> 'source', '') <> 'voice_call_summary'
     and (p_after is null or m.created_at >= p_after)
     and (p_before is null or m.created_at <= p_before)
     and (
       p_cursor_created_at is null
       or p_cursor_message_id is null
       or (m.created_at, m.id) < (p_cursor_created_at, p_cursor_message_id)
     )
  ),
  matched as (
    select
      candidate.*,
      array_remove(array[
        case when exists (
          select 1 from unnest((select tokens from normalized_tokens)) token
           where strpos(candidate.text_haystack, token) > 0
        ) then 'text' end,
        case when exists (
          select 1 from unnest((select tokens from normalized_tokens)) token
           where strpos(candidate.sender_haystack, token) > 0
        ) then 'sender' end,
        case when exists (
          select 1 from unnest((select tokens from normalized_tokens)) token
           where strpos(candidate.attachment_haystack, token) > 0
        ) then 'attachment' end,
        case when exists (
          select 1 from unnest((select tokens from normalized_tokens)) token
           where strpos(candidate.time_haystack, token) > 0
        ) then 'time' end
      ]::text[], null) as matched_fields
      from candidates candidate
     where cardinality((select tokens from normalized_tokens)) > 0
       and not exists (
         select 1
           from unnest((select tokens from normalized_tokens)) token
          where strpos(candidate.text_haystack, token) = 0
            and strpos(candidate.sender_haystack, token) = 0
            and strpos(candidate.attachment_haystack, token) = 0
            and strpos(candidate.time_haystack, token) = 0
       )
  )
  select
    matched.conversation_id,
    matched.conversation_title,
    matched.conversation_type,
    matched.message_id,
    matched.message_seq,
    matched.text,
    matched.sender_name,
    matched.sender_id,
    matched.created_at,
    matched.attachment_metadata,
    matched.matched_fields
  from matched
  order by matched.created_at desc, matched.message_id desc
  limit least(201, greatest(1, coalesce(p_limit, 51)));
$$;

revoke execute on function pendingbot.search_messages_for_user(
  uuid, text[], uuid, timestamptz, timestamptz, timestamptz, uuid, integer
) from public, anon, authenticated;
grant execute on function pendingbot.search_messages_for_user(
  uuid, text[], uuid, timestamptz, timestamptz, timestamptz, uuid, integer
) to service_role;

commit;
