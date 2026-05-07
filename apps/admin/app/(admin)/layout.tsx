import { requireAdmin } from '@/lib/auth';
import { Nav } from '@/components/nav';

// Auth gate + persistent nav for every protected page. requireAdmin
// runs once per request here; child pages no longer need to repeat
// the call (server actions still do — layouts don't run for those).
export default async function AdminLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const user = await requireAdmin();
  return (
    <>
      <Nav user={user} />
      {children}
    </>
  );
}
