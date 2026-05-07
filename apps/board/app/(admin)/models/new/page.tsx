import { ModelForm } from '../_form';
import { createModel } from '../actions';

export default function NewModelPage() {
  return (
    <main className="container max-w-2xl py-10 space-y-6">
      <h1 className="text-2xl font-bold tracking-tight">新增 model</h1>
      <ModelForm action={createModel} submitLabel="创建" />
    </main>
  );
}
