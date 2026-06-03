import { z } from 'zod';

// Supabase Auth issues asymmetric-signed JWTs (ES256/RS256/EdDSA per the
// project's key rotation) with these payload fields. Verified via the
// JWKS endpoint in jwt.ts — see that module for the algorithm allowlist
// and JWKS caching. The shape below is the minimum we rely on.

export const SupabaseJwtPayload = z.object({
  sub: z.string().uuid(),               // auth.users.id
  email: z.string().email().optional(),
  role: z.literal('authenticated'),     // only normal user sessions enter Edge routes
  aud: z.string().or(z.array(z.string()))
    .refine((aud) => Array.isArray(aud) ? aud.includes('authenticated') : aud === 'authenticated'),
  exp: z.number(),
  iat: z.number().optional(),
});
export type SupabaseJwtPayload = z.infer<typeof SupabaseJwtPayload>;
