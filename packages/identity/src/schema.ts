import { z } from 'zod';

// Supabase Auth issues asymmetric-signed JWTs (ES256/RS256/EdDSA per the
// project's key rotation) with these payload fields. Verified via the
// JWKS endpoint in jwt.ts — see that module for the algorithm allowlist
// and JWKS caching. The shape below is the minimum we rely on.

export const SupabaseJwtPayload = z.object({
  sub: z.string().uuid(),               // auth.users.id
  email: z.string().email().optional(),
  role: z.string().optional(),          // 'authenticated' for normal users
  aud: z.string().or(z.array(z.string())),
  exp: z.number(),
  iat: z.number().optional(),
});
export type SupabaseJwtPayload = z.infer<typeof SupabaseJwtPayload>;

// What our products know about a user, after combining auth.users + their
// own product-specific `users` table mirror (display_name, is_admin, etc.).
export const SessionUser = z.object({
  id: z.string().uuid(),
  email: z.string().email().nullable(),
  isAdmin: z.boolean(),
  jwt: z.string(),                       // raw JWT for downstream Supabase calls
});
export type SessionUser = z.infer<typeof SessionUser>;
