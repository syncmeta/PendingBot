import { useState } from 'react';
import { useLogin } from '@refinedev/core';

// Email/password login → Supabase Auth (authProvider.login). On success the
// JWT is persisted by supabase-js and attached to every edge call.
export const LoginPage = () => {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const { mutate, isPending, isError, error } = useLogin();

  return (
    <div
      style={{
        maxWidth: 360,
        margin: '80px auto',
        fontFamily: 'system-ui, sans-serif',
      }}
    >
      <h1 style={{ fontSize: 20 }}>PendingBot Admin</h1>
      <p style={{ fontSize: 13, opacity: 0.7 }}>仅限管理员。登录后所有操作经 edge 校验与审计。</p>
      <form
        onSubmit={(e) => {
          e.preventDefault();
          mutate({ email, password });
        }}
      >
        <input
          type="email"
          placeholder="邮箱"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          style={{ display: 'block', width: '100%', padding: 8, marginBottom: 8 }}
        />
        <input
          type="password"
          placeholder="密码"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          style={{ display: 'block', width: '100%', padding: 8, marginBottom: 8 }}
        />
        <button type="submit" disabled={isPending} style={{ width: '100%', padding: 8 }}>
          {isPending ? '登录中…' : '登录'}
        </button>
      </form>
      {isError ? (
        <div style={{ color: '#b00020', marginTop: 8, fontSize: 13 }}>
          {(error as { message?: string })?.message ?? '登录失败'}
        </div>
      ) : null}
    </div>
  );
};
