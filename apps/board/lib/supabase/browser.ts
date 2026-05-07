'use client';

import { createBrowserClient } from '@supabase/ssr';
import type { Database } from '@pendingbot/edge/db/schema';

// Browser client. Used by the login page to sign in (cookies get set
// on the response and the server then sees the session). After login,
// the rest of the panel is rendered server-side; the browser client
// is essentially only for auth flows.
export function supabaseBrowser() {
  return createBrowserClient<Database, 'pendingbot'>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    { db: { schema: 'pendingbot' } },
  );
}
