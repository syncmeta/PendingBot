'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { logoutAction } from '@/app/login/actions';

const LINKS: { href: string; label: string }[] = [
  { href: '/audit', label: 'Audit' },
  { href: '/arbitrage', label: 'Arbitrage' },
  { href: '/app-stats', label: 'App stats' },
  { href: '/providers', label: 'Providers' },
  { href: '/models', label: 'Models' },
  { href: '/aliases', label: 'Aliases' },
  { href: '/routing-rules', label: 'Routing' },
  { href: '/users', label: 'Users' },
  { href: '/admin-audit', label: 'Admin audit' },
];

export function Nav({
  user,
}: {
  user: { display_name: string; email: string | null };
}) {
  const pathname = usePathname();
  const isActive = (href: string) =>
    pathname === href || pathname.startsWith(href + '/');

  return (
    <header className="sticky top-0 z-10 border-b bg-background/90 backdrop-blur">
      <div className="container flex flex-wrap items-center gap-x-6 gap-y-2 py-3">
        <Link href="/" className="text-sm font-semibold tracking-tight">
          Board
        </Link>
        <nav className="flex flex-wrap items-center gap-x-4 gap-y-1 text-sm">
          {LINKS.map((l) => {
            const active = isActive(l.href);
            return (
              <Link
                key={l.href}
                href={l.href}
                className={
                  active
                    ? 'font-medium text-foreground'
                    : 'text-muted-foreground transition hover:text-foreground'
                }
              >
                {l.label}
              </Link>
            );
          })}
        </nav>
        <div className="ml-auto flex items-center gap-3 text-sm">
          <span className="hidden text-muted-foreground sm:inline">
            {user.display_name || user.email}
          </span>
          <form action={logoutAction}>
            <button
              type="submit"
              className="rounded-md border border-input px-2.5 py-1 text-xs hover:bg-accent"
            >
              退出
            </button>
          </form>
        </div>
      </div>
    </header>
  );
}
