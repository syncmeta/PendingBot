'use client';

import { useState, useTransition } from 'react';

type GenerateResult = { code?: string; email?: string; error?: string };

/// 行内"生成登录码"按钮 — 调服务端 generateLoginCode,把返回的 6 位 OTP
/// 就地展示并写入剪贴板,30 秒后自动收起。不弹窗、不发邮件,纯支援场景:
/// 用户拿不到自己邮箱里的码时,admin 当面把码读给 ta。
export function GenerateLoginCodeButton({
  action,
  userId,
}: {
  action: (userId: string) => Promise<GenerateResult>;
  userId: string;
}) {
  const [pending, startTransition] = useTransition();
  const [shown, setShown] = useState<{ code: string } | null>(null);

  const onClick = () => {
    startTransition(async () => {
      const res = await action(userId);
      if (res.error || !res.code) {
        window.alert(`生成失败: ${res.error ?? '未知错误'}`);
        return;
      }
      try {
        await navigator.clipboard.writeText(res.code);
      } catch {
        // 剪贴板失败不阻断 — 码本身已经显示出来了
      }
      setShown({ code: res.code });
      setTimeout(() => setShown(null), 30_000);
    });
  };

  if (shown) {
    return (
      <button
        type="button"
        onClick={() => setShown(null)}
        className="rounded border border-emerald-500/40 bg-emerald-50 px-2 py-1 text-xs font-mono text-emerald-700 hover:bg-emerald-100"
        title="点击隐藏。30 秒后自动消失。"
      >
        {shown.code} <span className="text-muted-foreground">(已复制)</span>
      </button>
    );
  }

  return (
    <button
      type="button"
      onClick={onClick}
      disabled={pending}
      className="rounded border border-input px-2 py-1 text-xs hover:bg-accent disabled:opacity-50"
      title="生成 6 位邮箱登录码 — 直接显示,不发邮件"
    >
      {pending ? '生成中...' : '生成登录码'}
    </button>
  );
}
