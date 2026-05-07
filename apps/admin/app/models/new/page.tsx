import Link from 'next/link';
import { requireAdmin } from '@/lib/auth';
import { ModelForm } from '../_form';
import { createModel } from '../actions';

export default async function NewModelPage() {
  await requireAdmin();
  return (
    <main className="container max-w-2xl py-10 space-y-6">
      <header>
        <h1 className="text-2xl font-bold tracking-tight">新增 model</h1>
        <p className="text-sm text-muted-foreground">
          <Link href="/models" className="underline">
            ← 返回列表
          </Link>
        </p>
      </header>
      <ModelForm action={createModel} submitLabel="创建" />
    </main>
  );
}
