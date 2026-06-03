import { createClient } from '@supabase/supabase-js';
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './env';

// Supabase Auth client — the admin SPA's ONLY use of Supabase directly is
// authentication (email/password → JWT). It never touches the `pendingbot`
// schema directly; all data access goes through the edge API with the JWT
// attached as a Bearer token. The anon key is RLS-gated and safe in the
// browser; the service-role key is NEVER shipped here (see .env.example).
//
// persistSession: true → the session (incl. refresh token) is stored in
// localStorage so an admin stays logged in across reloads. autoRefreshToken
// keeps the access token fresh; the dataProvider reads the current token on
// every request via getAccessToken().
export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: false,
  },
});

// Current access token (Supabase JWT) or null. The edge `requireSession`
// middleware (packages/identity) verifies this against the project JWKS.
export async function getAccessToken(): Promise<string | null> {
  const { data } = await supabase.auth.getSession();
  return data.session?.access_token ?? null;
}
