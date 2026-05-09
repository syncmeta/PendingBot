/** @type {import('next').NextConfig} */
const nextConfig = {
  // Reuse the edge worker's generated Supabase types for row shapes
  // without copying the file. transpilePackages keeps Next happy when
  // importing TypeScript from a sibling workspace package.
  transpilePackages: ['@pendingbot/edge'],

  // `undici` is loaded by instrumentation.ts to install a ProxyAgent
  // as Node's global fetch dispatcher. It's a Node-only package that
  // Next's bundler can't trace (dynamic import + native deps), so
  // mark it external and let Node resolve it at runtime.
  serverExternalPackages: ['undici'],
};

export default nextConfig;
