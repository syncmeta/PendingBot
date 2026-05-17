// Shared type for the preset-letter editor page and its server action.
// Lives here (not in actions.ts) because Next.js 'use server' files may
// only export async functions.

export type SaveLetterState = { error?: string; ok?: boolean };
