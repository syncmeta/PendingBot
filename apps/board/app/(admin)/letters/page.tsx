import { supabaseAdmin } from '@/lib/supabase/admin';
import { LetterEditor } from './editor';

export default async function LettersPage() {
  const supa = supabaseAdmin();
  const { data: row } = await supa
    .from('preset_letters')
    .select('title, summary, body_md, version, updated_at')
    .eq('slug', 'readme')
    .maybeSingle();

  return (
    <main className="container py-10 space-y-6">
      <header className="space-y-1">
        <h1 className="text-2xl font-bold tracking-tight">预设来信</h1>
        <p className="text-sm text-muted-foreground">
          每个新用户首次打开「来信」时自动收到的一封预置来信（和预设会话同
          理）。改这里只影响之后注册的新用户；已注册用户那封不会被覆盖。
        </p>
        {row && (
          <p className="text-xs text-muted-foreground">
            v{row.version}，更新于{' '}
            {new Date(row.updated_at).toLocaleString('zh-CN')}
          </p>
        )}
      </header>

      <LetterEditor
        initialTitle={row?.title ?? ''}
        initialSummary={row?.summary ?? ''}
        initialBody={row?.body_md ?? ''}
      />
    </main>
  );
}
