import { useCallback, useEffect, useRef, useState } from 'react';
import { useLogin } from '@refinedev/core';
import { TURNSTILE_SITE_KEY } from '../env';

// Turnstile explicit-render API, loaded on demand (login page only).
// https://developers.cloudflare.com/turnstile/get-started/client-side-rendering/
declare global {
  interface Window {
    turnstile?: {
      render: (
        el: HTMLElement,
        opts: {
          sitekey: string;
          callback: (token: string) => void;
          'expired-callback'?: () => void;
          'error-callback'?: () => void;
        },
      ) => string;
      reset: (widgetId: string) => void;
    };
  }
}

const TURNSTILE_SRC = 'https://challenges.cloudflare.com/turnstile/api.js?render=explicit';

function loadTurnstile(): Promise<void> {
  if (window.turnstile) return Promise.resolve();
  return new Promise((resolve, reject) => {
    const existing = document.querySelector<HTMLScriptElement>(`script[src="${TURNSTILE_SRC}"]`);
    if (existing) {
      existing.addEventListener('load', () => resolve());
      existing.addEventListener('error', reject);
      return;
    }
    const script = document.createElement('script');
    script.src = TURNSTILE_SRC;
    script.async = true;
    script.onload = () => resolve();
    script.onerror = reject;
    document.head.appendChild(script);
  });
}

// Email/password login → Supabase Auth (authProvider.login). On success the
// JWT is persisted by supabase-js and attached to every edge call.
// Supabase Auth captcha protection requires a Turnstile token on every
// signInWithPassword; tokens are single-use, so reset the widget after a
// failed submit.
export const LoginPage = () => {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [captchaToken, setCaptchaToken] = useState<string | undefined>();
  const widgetRef = useRef<HTMLDivElement>(null);
  const widgetIdRef = useRef<string | undefined>(undefined);
  const { mutate, isPending, isError, error } = useLogin();

  useEffect(() => {
    if (!TURNSTILE_SITE_KEY || !widgetRef.current) return;
    let cancelled = false;
    loadTurnstile().then(() => {
      if (cancelled || !window.turnstile || !widgetRef.current) return;
      if (widgetIdRef.current) return; // already rendered (StrictMode remount)
      widgetIdRef.current = window.turnstile.render(widgetRef.current, {
        sitekey: TURNSTILE_SITE_KEY as string,
        callback: (token) => setCaptchaToken(token),
        'expired-callback': () => setCaptchaToken(undefined),
        'error-callback': () => setCaptchaToken(undefined),
      });
    });
    return () => {
      cancelled = true;
    };
  }, []);

  const resetCaptcha = useCallback(() => {
    setCaptchaToken(undefined);
    if (widgetIdRef.current && window.turnstile) {
      window.turnstile.reset(widgetIdRef.current);
    }
  }, []);

  const captchaRequired = Boolean(TURNSTILE_SITE_KEY);
  const submitDisabled = isPending || (captchaRequired && !captchaToken);

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
          mutate(
            { email, password, captchaToken },
            // A consumed token can't be reused — re-arm the widget so the
            // user can retry after a wrong password.
            { onError: resetCaptcha, onSettled: (data) => data?.success || resetCaptcha() },
          );
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
        {captchaRequired ? <div ref={widgetRef} style={{ marginBottom: 8 }} /> : null}
        <button type="submit" disabled={submitDisabled} style={{ width: '100%', padding: 8 }}>
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
