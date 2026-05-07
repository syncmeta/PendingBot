'use server';

import { redirect } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { supabaseAdmin } from '@/lib/supabase/admin';

export type LoginState = { error?: string };

export async function loginAction(_prev: LoginState, formData: FormData): Promise<LoginState> {
  const email = String(formData.get('email') ?? '').trim();
  const password = String(formData.get('password') ?? '');

  if (!email || !password) {
    return { error: '邮箱和密码都要填' };
  }

  const supa = await supabaseServer();
  const { data, error } = await supa.auth.signInWithPassword({ email, password });

  if (error || !data.user) {
    return { error: error?.message ?? '登录失败' };
  }

  // Admin gate at login time: bounce non-admins immediately so
  // they don't sit in a session that requireAdmin() will reject on
  // every page anyway.
  const admin = supabaseAdmin();
  const { data: row } = await admin
    .from('users')
    .select('is_admin')
    .eq('id', data.user.id)
    .maybeSingle();

  if (!row?.is_admin) {
    await supa.auth.signOut();
    return { error: '该账号不是 admin' };
  }

  redirect('/');
}

export async function logoutAction() {
  const supa = await supabaseServer();
  await supa.auth.signOut();
  redirect('/login');
}
