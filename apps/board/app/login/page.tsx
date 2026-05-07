'use client';

import { useActionState } from 'react';
import { loginAction, type LoginState } from './actions';

export default function LoginPage() {
  const [state, formAction, pending] = useActionState<LoginState, FormData>(loginAction, {});

  return (
    <main className="container max-w-sm py-24">
      <h1 className="text-2xl font-bold tracking-tight">Board</h1>
      <p className="mt-1 text-sm text-muted-foreground">
        用 Supabase 账号登录。账号需要 <code>users.is_admin = true</code>。
      </p>

      <form action={formAction} className="mt-8 space-y-4">
        <div>
          <label className="block text-sm font-medium" htmlFor="email">
            邮箱
          </label>
          <input
            id="email"
            name="email"
            type="email"
            required
            autoComplete="email"
            className="mt-1 block w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
          />
        </div>
        <div>
          <label className="block text-sm font-medium" htmlFor="password">
            密码
          </label>
          <input
            id="password"
            name="password"
            type="password"
            required
            autoComplete="current-password"
            className="mt-1 block w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
          />
        </div>

        {state.error && (
          <p className="rounded-md border border-destructive/50 bg-destructive/10 px-3 py-2 text-sm text-destructive">
            {state.error}
          </p>
        )}

        <button
          type="submit"
          disabled={pending}
          className="w-full rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-foreground disabled:opacity-50"
        >
          {pending ? '登录中…' : '登录'}
        </button>
      </form>
    </main>
  );
}
