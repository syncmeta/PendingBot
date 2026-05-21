// Constants and types shared between the prompts admin pages and the server
// actions. They live here (not in actions.ts) because Next.js requires
// 'use server' files to export only async functions — re-exporting a const
// array or a type alias from actions.ts trips the action-validator check.

export const SUPPORTED_LOCALES = ['zh', 'en'] as const;
export type PromptLocale = (typeof SUPPORTED_LOCALES)[number];

export type SavePromptState = {
  error?: string;
  ok?: boolean;
  // Result of mirroring the save into the repo's bundled .md (best-effort;
  // only meaningful when Board runs locally with the monorepo source on disk).
  bundled?: { ok: true; path: string } | { ok: false; error: string };
};
