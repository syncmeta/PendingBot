import { Suspense } from 'react';
import { requireAdmin } from '@/lib/auth';
import { Nav } from '@/components/nav';
import { FlashToastReader, ToastProvider } from '@/components/toast';

// Auth gate + persistent nav for every protected page. requireAdmin
// runs once per request here; child pages no longer need to repeat
// the call (server actions still do — layouts don't run for those).
//
// The ToastProvider wraps the whole protected area so every action
// surface (form pages, inline buttons, list-row controls) can push
// pending / success / error toasts via useToast(). FlashToastReader
// picks up ?toast=...&toastKind=... from URLs that a server action
// redirected to with `withFlash()` — that's how create/update flows
// announce success after a redirect.
export default async function AdminLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const user = await requireAdmin();
  return (
    <ToastProvider>
      <Nav user={user} />
      <Suspense fallback={null}>
        <FlashToastReader />
      </Suspense>
      {children}
    </ToastProvider>
  );
}
