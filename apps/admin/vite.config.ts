import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Static SPA build. Output → dist/ (the directory `wrangler pages deploy dist`
// uploads). SPA fallback for client-side routing is handled by public/_redirects
// (Cloudflare Pages convention: `/* /index.html 200`).
export default defineConfig({
  plugins: [react()],
  build: {
    outDir: 'dist',
    sourcemap: false,
  },
});
