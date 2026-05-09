/** @type {import('next').NextConfig} */
const nextConfig = {
  // Reuse the edge worker's generated Supabase types for row shapes
  // without copying the file. transpilePackages keeps Next happy when
  // importing TypeScript from a sibling workspace package.
  transpilePackages: ['@pendingbot/edge'],

  // `undici` is loaded by instrumentation.ts to install a ProxyAgent
  // as Node's global fetch dispatcher. It's a Node-only package that
  // Next's bundler can't trace (uses `node:` schemed built-ins), so
  // mark it external and let Node resolve it at runtime.
  serverExternalPackages: ['undici'],

  // serverExternalPackages alone doesn't reach the instrumentation
  // chunk in Next 15 — webpack still recurses into undici and chokes
  // on `node:console`. Push undici onto webpack's server externals
  // explicitly so the dynamic import in instrumentation.ts resolves
  // at runtime via Node's require, not at build time.
  webpack: (config, { isServer }) => {
    if (isServer) {
      const externals = config.externals;
      config.externals = [
        ...(Array.isArray(externals) ? externals : externals ? [externals] : []),
        'undici',
      ];
    }
    return config;
  },
};

export default nextConfig;
