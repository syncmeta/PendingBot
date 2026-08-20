// Cross-product identity package — shared by all PendingBot products that
// authenticate via Supabase Auth.
//
// One Supabase project's auth.users table is the single source of truth;
// each product app has its own business schema (pendingbot.*, etc.) and
// imports this package to verify user JWTs and inject userId/role into
// request context.

export * from './schema';
export * from './middleware';
export * from './jwt';
