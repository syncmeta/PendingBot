import { ProviderForm } from '../_form';
import { createProvider } from '../actions';

export default function NewProviderPage() {
  return (
    <main className="container max-w-2xl py-10 space-y-6">
      <h1 className="text-2xl font-bold tracking-tight">新增 provider</h1>
      <ProviderForm action={createProvider} submitLabel="创建" />
    </main>
  );
}
