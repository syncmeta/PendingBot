import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import type { Env } from '../types';

// Two flavors of supabase-js client:
//
//   userClient(env, userJwt)
//     RLS守门 — 用户行为代理 (e.g. 写入 messages 时 RLS 验"我是
//     conversation_participants 之一"). 客户端直读用同样模式但不经
//     Worker.
//
//   serviceClient(env)
//     绕过 RLS — 后台任务、admin 写、跨用户的 derived data
//     (user_unread_counts trigger 反向不需要)。**慎用**：只在
//     业务逻辑确定要做"非用户身份"的写入时调。

export function userClient(env: Env, userJwt: string): SupabaseClient {
  return createClient(env.SUPABASE_URL, env.SUPABASE_ANON_KEY, {
    global: {
      headers: { Authorization: `Bearer ${userJwt}` },
    },
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
  });
}

export function serviceClient(env: Env): SupabaseClient {
  return createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
  });
}
