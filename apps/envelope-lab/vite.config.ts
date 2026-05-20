import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Local-only dev panel for the 来信 (envelope) loop. Vite serves the
// React UI; Hono lives on a sibling port and is proxied for `/api/*`.
export default defineConfig({
  plugins: [react()],
  server: {
    port: 5174,
    proxy: {
      '/api': {
        target: 'http://localhost:5175',
        changeOrigin: true,
      },
    },
  },
});
