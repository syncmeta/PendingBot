import { jwtVerify } from 'jose';
import { SupabaseJwtPayload } from './schema';

// Verify a Supabase Auth JWT (HS256, signed with project's JWT secret).
// Returns the parsed payload on success; throws on bad signature / expired.

export async function verifySupabaseJwt(
  token: string,
  jwtSecret: string,
): Promise<SupabaseJwtPayload> {
  const secret = new TextEncoder().encode(jwtSecret);
  const { payload } = await jwtVerify(token, secret, {
    algorithms: ['HS256'],
  });
  return SupabaseJwtPayload.parse(payload);
}
