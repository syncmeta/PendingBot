import 'server-only';

import { redirect } from 'next/navigation';
import { supabaseServer } from './supabase/server';
import { supabaseAdmin } from './supabase/admin';

export type AdminUser = {
  id: string;
  email: string | null;
  display_name: string;
};

// Two-step gate:
//   1. Supabase Auth session exists (else /login)
//   2. The mapped pendingbot.users row has is_admin = true (else 403)
//
// We intentionally do the is_admin lookup with the service-role client.
// pendingbot.users has RLS that hides other users' rows even from
// authenticated callers; checking your own admin flag with the user
// client would work, but using service role here keeps the gate logic
// uniform with how the rest of the panel reads admin tables.
export async function requireAdmin(): Promise<AdminUser> {
  const supa = await supabaseServer();
  const {
    data: { user },
  } = await supa.auth.getUser();

  if (!user) {
    redirect('/login');
  }

  const admin = supabaseAdmin();
  const { data: row, error } = await admin
    .from('users')
    .select('id, email, display_name, is_admin')
    .eq('id', user.id)
    .maybeSingle();

  if (error || !row || !row.is_admin) {
    redirect('/login?error=not_admin');
  }

  return {
    id: row.id,
    email: row.email,
    display_name: row.display_name,
  };
}
