import { createServerClient, type CookieOptions } from '@supabase/ssr';
import { cookies } from 'next/headers';
import type { Database } from '@pendingbot/edge/db/schema';

// Server-side Supabase client bound to the Next.js cookie store. Use
// inside server components, route handlers, and server actions to read
// the current user's session. RLS applies — this client speaks as the
// signed-in user.
export async function supabaseServer() {
  const cookieStore = await cookies();
  return createServerClient<Database, 'pendingbot'>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll: () => cookieStore.getAll(),
        setAll: (cookiesToSet: { name: string; value: string; options: CookieOptions }[]) => {
          try {
            cookiesToSet.forEach(({ name, value, options }) =>
              cookieStore.set(name, value, options),
            );
          } catch {
            // setAll throws when called from a Server Component (cookies
            // are read-only there). Middleware refreshes sessions so
            // this is fine to swallow — the session stays valid.
          }
        },
      },
      db: { schema: 'pendingbot' },
    },
  );
}
