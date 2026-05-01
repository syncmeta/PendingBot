-- service_role needs explicit USAGE on non-public schemas; RLS bypass alone
-- isn't enough. Without this, PostgREST returns 42501 on /rest/v1/*.
grant usage on schema pendingbot to service_role;
grant select, insert, update, delete on all tables in schema pendingbot to service_role;
alter default privileges in schema pendingbot
  grant select, insert, update, delete on tables to service_role;
