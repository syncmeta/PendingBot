import { z } from 'zod';

export const AppKind = z.enum(['pendingbot_macos', 'pendingcrew_macos']);
export const GrantKind = z.enum(['pendingbot_client', 'pendingcrew_control', 'pendingcrew_runner']);
export const Scope = z.enum([
  'subject:read',
  'crew:read',
  'crew:write',
  'runner:read',
  'runner:write',
]);

const byteAlphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

function randomText(length: number): string {
  const bytes = new Uint8Array(length);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (byte) => byteAlphabet[byte % byteAlphabet.length]).join('');
}

export function randomToken(prefix: string): string {
  return `${prefix}_${randomText(48)}`;
}

export async function sha256Hex(input: string): Promise<string> {
  const bytes = new TextEncoder().encode(input);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('');
}

export function appGrantCompatible(appKind: z.infer<typeof AppKind>, grantKind: z.infer<typeof GrantKind>): boolean {
  if (appKind === 'pendingbot_macos') return grantKind === 'pendingbot_client';
  return grantKind === 'pendingcrew_control' || grantKind === 'pendingcrew_runner';
}

export function allowedScopesForGrant(grantKind: z.infer<typeof GrantKind>): Set<z.infer<typeof Scope>> {
  switch (grantKind) {
    case 'pendingbot_client':
      return new Set(['subject:read', 'crew:read', 'crew:write']);
    case 'pendingcrew_control':
      return new Set(['subject:read', 'crew:read', 'crew:write', 'runner:read', 'runner:write']);
    case 'pendingcrew_runner':
      return new Set(['subject:read', 'runner:read', 'runner:write']);
  }
}

export function scopesSubsetOf(requested: readonly z.infer<typeof Scope>[], allowed: ReadonlySet<string>): boolean {
  return requested.every((scope) => allowed.has(scope));
}
