import type { AuthProvider } from '@refinedev/core';
import { supabase } from '../supabase';
import { edgeFetch, EdgeApiError } from './http';

// ─────────────────────────────────────────────────────────────────────────
// AuthProvider — Supabase Auth (email/password) → JWT, then edge verifies.
// Verified against the official @refinedev/core@5.0.12 contract
// (https://refine.dev/docs/authentication/auth-provider/):
//   login          → { success, redirectTo?, error? }
//   logout         → { success, redirectTo?, error? }
//   check          → { authenticated, redirectTo?, logout?, error? }
//   onError        → { redirectTo?, logout?, error? }
//   getIdentity    → Promise<unknown>   (optional)
//   getPermissions → Promise<unknown>   (optional)
//
// Admin gating: there is no public "am I admin" edge endpoint yet (users.is_admin
// exists in DB; no route exposes it). We authenticate via Supabase and treat a
// valid session as logged-in; the EDGE enforces is_admin on every admin route
// (once those routes exist). getIdentity calls GET /v1/me/profile (EXISTS) just
// to confirm the JWT is accepted by edge. If/when an admin-claim endpoint lands,
// tighten `check` to reject non-admins client-side too (logged to tech-debt).
// ─────────────────────────────────────────────────────────────────────────

type LoginVars = { email?: string; password?: string };

export const authProvider: AuthProvider = {
  login: async ({ email, password }: LoginVars) => {
    if (!email || !password) {
      return { success: false, error: { name: 'LoginError', message: '请输入邮箱和密码' } };
    }
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) {
      return {
        success: false,
        error: { name: 'LoginError', message: error.message },
      };
    }
    return { success: true, redirectTo: '/' };
  },

  logout: async () => {
    await supabase.auth.signOut();
    return { success: true, redirectTo: '/login' };
  },

  check: async () => {
    const { data } = await supabase.auth.getSession();
    if (data.session) {
      return { authenticated: true };
    }
    return {
      authenticated: false,
      logout: true,
      redirectTo: '/login',
      error: { name: 'Unauthorized', message: '请先登录' },
    };
  },

  // Map an edge 401 (expired/invalid JWT) to a forced logout so the UI bounces
  // to /login rather than spinning on a dead session.
  onError: async (error) => {
    if (error instanceof EdgeApiError && error.statusCode === 401) {
      return { logout: true, redirectTo: '/login', error };
    }
    return { error };
  },

  getIdentity: async () => {
    const { data } = await supabase.auth.getSession();
    const session = data.session;
    if (!session) return null;
    // Confirm the JWT is accepted by edge (GET /v1/me/profile EXISTS and is
    // session-gated). Non-fatal if it fails — we still know who the user is
    // from the Supabase session.
    let edgeOk = false;
    try {
      await edgeFetch({ method: 'GET', path: 'me/profile' });
      edgeOk = true;
    } catch {
      edgeOk = false;
    }
    return {
      id: session.user.id,
      name: session.user.email ?? session.user.id,
      email: session.user.email,
      edgeReachable: edgeOk,
    };
  },

  getPermissions: async () => {
    // No client-side role source yet (is_admin is DB-only). Edge is the
    // authority. Returns null until an admin-claim endpoint exists.
    return null;
  },
};
