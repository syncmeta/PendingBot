import Link from 'next/link';
import { requireAdmin } from '@/lib/auth';
import { ProviderForm } from '../_form';
import { createProvider } from '../actions';

export default async function NewProviderPage() {
  await requireAdmin();
  return (
    <main className="container max-w-2xl py-10 space-y-6">
      <header>
        <h1 className="text-2xl font-bold tracking-tight">新增 provider</h1>
        <p className="text-sm text-muted-foreground">
          <Link href="/providers" className="underline">
            ← 返回列表
          </Link>
        </p>
      </header>
      <ProviderForm action={createProvider} submitLabel="创建" />
    </main>
  );
}
