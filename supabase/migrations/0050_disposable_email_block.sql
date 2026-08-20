-- Disposable / throwaway email domain blocklist.
--
-- Why a DB-level check instead of validating in the iOS / edge client:
-- the client is on the wrong side of the trust boundary, and Apple SIWA
-- + Google sign-in skip our app code entirely on first-time signup —
-- they hand a fully-formed user straight into auth.users. A BEFORE
-- INSERT trigger on auth.users is the only point that catches every
-- signup path, including OAuth providers we don't write code for.
--
-- We deliberately ship a small, high-confidence list of well-known
-- disposable services rather than the 3000-entry community dump —
-- the long tail has too many false positives (niche legit providers,
-- privacy-focused consumer mail, regional hosts) and the top ~80
-- already cover the dominant share of attacker traffic. Add new
-- entries as we observe abuse; remove an entry if a real user ever
-- complains.

create table pendingbot.disposable_email_domains (
  domain     text primary key,
  added_at   timestamptz not null default now(),
  note       text
);

comment on table pendingbot.disposable_email_domains is
  'Email domains rejected at signup. Curated, not auto-synced; '
  'extend manually as abuse patterns shift.';

-- Trigger function. Runs BEFORE INSERT on auth.users so the user row
-- is never created when the domain matches — Supabase Auth bubbles
-- the SQLSTATE / message back to the client as a 400.
--
-- Apple's private-email-relay service (`@privaterelay.appleid.com`)
-- is intentionally NOT in the blocklist; it's a legitimate Apple
-- forwarder used by Sign in with Apple's "Hide My Email" option and
-- represents real users.
create or replace function pendingbot.reject_disposable_email()
returns trigger
language plpgsql
security definer
set search_path = pendingbot, public
as $$
declare
  v_domain text;
begin
  if new.email is null or position('@' in new.email) = 0 then
    return new;
  end if;

  v_domain := lower(split_part(new.email, '@', 2));

  if exists (
    select 1 from pendingbot.disposable_email_domains
    where domain = v_domain
  ) then
    raise exception 'email_domain_not_allowed'
      using errcode = 'P0001',
            hint    = 'Use a permanent email address, not a temporary one.';
  end if;

  return new;
end;
$$;

drop trigger if exists reject_disposable_email_on_signup on auth.users;
create trigger reject_disposable_email_on_signup
  before insert on auth.users
  for each row
  execute function pendingbot.reject_disposable_email();

-- Initial seed. Curated from the highest-traffic disposable-email
-- services. Variants of the same provider are listed individually
-- because each domain resolves separately at signup time.
insert into pendingbot.disposable_email_domains (domain) values
  -- Mailinator family
  ('mailinator.com'), ('mailinator.net'), ('mailinator2.com'),
  ('notmailinator.com'),
  -- 10minutemail family
  ('10minutemail.com'), ('10minutemail.net'), ('10minutemail.de'),
  ('20minutemail.com'), ('20minutemail.it'),
  -- Guerrilla Mail family
  ('guerrillamail.com'), ('guerrillamail.net'), ('guerrillamail.org'),
  ('guerrillamail.de'), ('guerrillamail.biz'), ('guerrillamailblock.com'),
  ('sharklasers.com'), ('grr.la'), ('spam4.me'),
  -- YOPmail
  ('yopmail.com'), ('yopmail.fr'), ('yopmail.net'),
  -- Temp-Mail family
  ('temp-mail.org'), ('temp-mail.io'), ('temp-mail.com'),
  ('tempmail.com'), ('tempmail.net'), ('tempmail.de'),
  ('tempmailo.com'), ('tempmailaddress.com'), ('tempinbox.com'),
  ('tmpmail.org'), ('tmpmail.net'), ('tempr.email'),
  -- Trash Mail family
  ('trashmail.com'), ('trashmail.net'), ('trashmail.io'),
  ('trashmail.de'), ('trashmail.org'), ('trashmail.me'),
  ('trashmail.ws'), ('mailmetrash.com'),
  -- Maildrop / dropmail
  ('maildrop.cc'), ('dropmail.me'),
  -- Throwaway / Discard
  ('throwaway.email'), ('throwawaymail.com'),
  ('discard.email'), ('discardmail.com'), ('discardmail.de'),
  ('dispostable.com'), ('deadaddress.com'),
  -- Nada / Getnada
  ('getnada.com'), ('nada.email'),
  -- Spambog family
  ('spambog.com'), ('spambog.de'), ('spambog.ru'),
  ('spambox.us'), ('spamgourmet.com'), ('spamgourmet.net'),
  -- Fake mail family
  ('fake-mail.net'), ('fake-mail.org'), ('fake-mail.com'),
  ('fakemail.net'), ('fakemail.fr'), ('fakemailgenerator.com'),
  ('fakeinbox.com'),
  -- Misc high-volume providers
  ('mohmal.com'), ('inboxbear.com'), ('inboxkitten.com'),
  ('emailondeck.com'), ('mintemail.com'), ('mailcatch.com'),
  ('mailnesia.com'), ('mailtemp.info'), ('mytemp.email'),
  ('mailnull.com'), ('mailforspam.com'), ('mailexpire.com'),
  ('mailpoof.com'), ('mvrht.com'), ('moakt.com'), ('moakt.cc'),
  ('jetable.org'), ('33mail.com'), ('chacuo.net'),
  ('dodgit.com'), ('filzmail.com'), ('incognitomail.org'),
  ('linshiyouxiang.net'), ('emltmp.com'), ('emlhub.com')
on conflict (domain) do nothing;
