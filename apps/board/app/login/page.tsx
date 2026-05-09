'use client';

import Script from 'next/script';
import { useActionState, useEffect, useRef, useState } from 'react';
import { loginAction, type LoginState } from './actions';

// Public site key. When Supabase Auth has captcha protection enabled,
// signInWithPassword requires a token from the matching widget. Same
// key the iOS client uses; localhost is allowed by Turnstile by
// default so dev just works. Empty value disables the widget for envs
// where captcha is off.
const SITE_KEY = process.env.NEXT_PUBLIC_TURNSTILE_SITE_KEY ?? '';

declare global {
  interface Window {
    turnstile?: {
      render: (
        el: string | HTMLElement,
        opts: {
          sitekey: string;
          callback?: (token: string) => void;
          'error-callback'?: () => void;
          'expired-callback'?: () => void;
        },
      ) => string;
      reset: (id?: string) => void;
      remove: (id?: string) => void;
    };
  }
}

export default function LoginPage() {
  const [state, formAction, pending] = useActionState<LoginState, FormData>(loginAction, {});
  const [token, setToken] = useState('');
  const widgetRef = useRef<HTMLDivElement | null>(null);
  const widgetIdRef = useRef<string | null>(null);

  // Render the widget once the Turnstile script has loaded. Polling
  // guards against the script being injected by next/script *after*
  // this effect first runs.
  useEffect(() => {
    if (!SITE_KEY) return;
    let cancelled = false;
    const render = () => {
      if (cancelled || widgetIdRef.current) return true;
      if (!window.turnstile || !widgetRef.current) return false;
      widgetIdRef.current = window.turnstile.render(widgetRef.current, {
        sitekey: SITE_KEY,
        callback: (t) => setToken(t),
        'error-callback': () => setToken(''),
        'expired-callback': () => setToken(''),
      });
      return true;
    };
    if (!render()) {
      const iv = setInterval(() => {
        if (render()) clearInterval(iv);
      }, 200);
      return () => {
        cancelled = true;
        clearInterval(iv);
      };
    }
  }, []);

  // After a failed submit the consumed token is dead — reset the
  // widget so the user can retry without reloading.
  useEffect(() => {
    if (!state.error) return;
    setToken('');
    if (widgetIdRef.current && window.turnstile) {
      window.turnstile.reset(widgetIdRef.current);
    }
  }, [state]);

  const captchaRequired = Boolean(SITE_KEY);
  const submitDisabled = pending || (captchaRequired && !token);

  return (
    <main className="container max-w-sm py-24">
      {captchaRequired && (
        <Script src="https://challenges.cloudflare.com/turnstile/v0/api.js" async defer />
      )}
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

        {captchaRequired && (
          <>
            <div ref={widgetRef} className="flex justify-center" />
            <input type="hidden" name="captchaToken" value={token} />
          </>
        )}

        {state.error && (
          <p className="rounded-md border border-destructive/50 bg-destructive/10 px-3 py-2 text-sm text-destructive">
            {state.error}
          </p>
        )}

        <button
          type="submit"
          disabled={submitDisabled}
          className="w-full rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-foreground disabled:opacity-50"
        >
          {pending ? '登录中…' : '登录'}
        </button>
      </form>
    </main>
  );
}
