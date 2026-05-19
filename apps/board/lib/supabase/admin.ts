import { createClient } from '@supabase/supabase-js';
import type { Database } from '@pendingbot/edge/db/schema';

// Service-role client. Bypasses RLS. Server-only — never call this
// from a client component or expose its outputs raw to the browser.
//
// Use for: reading admin-only tables (admin_audit, billing_config),
// aggregating audit_log across users, any write that needs to ignore RLS.
//
// requireAdmin() in lib/auth.ts must run *before* you reach for this
// — it gates access to the route in the first place.
export function supabaseAdmin() {
  return createClient<Database, 'pendingbot'>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!,
    {
      auth: { autoRefreshToken: false, persistSession: false },
      db: { schema: 'pendingbot' },
    },
  );
}
