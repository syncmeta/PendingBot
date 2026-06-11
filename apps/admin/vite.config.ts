import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Static SPA build, served by the edge worker under bot.pendingname.com/board
// (Workers assets binding in apps/edge/wrangler.jsonc — same origin as the
// API so the Cloudflare Access cookie covers both the page and /v1/board/*).
// `base` prefixes built asset URLs with /board/; the worker strips the prefix
// before ASSETS.fetch. SPA fallback = assets.not_found_handling.
export default defineConfig({
  plugins: [react()],
  base: '/board/',
  build: {
    outDir: 'dist',
    sourcemap: false,
  },
});
