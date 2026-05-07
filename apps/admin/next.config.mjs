/** @type {import('next').NextConfig} */
const nextConfig = {
  // Reuse the edge worker's generated Supabase types for row shapes
  // without copying the file. transpilePackages keeps Next happy when
  // importing TypeScript from a sibling workspace package.
  transpilePackages: ['@pendingbot/edge'],
  experimental: {
    typedRoutes: true,
  },
};

export default nextConfig;
