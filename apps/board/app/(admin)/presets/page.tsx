import { supabaseAdmin } from '@/lib/supabase/admin';
import { LetterEditor } from '../letters/editor';
import { PresetConversationForm, PresetGroupForm } from './editor';

export default async function PresetsPage() {
  const supa = supabaseAdmin();
  const [{ data: conversations }, { data: groups }, { data: letter }] =
    await Promise.all([
      supa
        .from('preset_conversation_templates')
        .select('*')
        .order('sort_order', { ascending: true }),
      supa
        .from('preset_group_templates')
        .select('*')
        .order('sort_order', { ascending: true }),
      supa
        .from('preset_letters')
        .select('title, summary, body_md, version, updated_at')
        .eq('slug', 'readme')
        .maybeSingle(),
    ]);

  return (
    <main className="container py-10 space-y-10">
      <header className="space-y-1">
        <h1 className="text-2xl font-bold tracking-tight">预设</h1>
        <p className="text-sm text-muted-foreground">
          管理新用户初始化时看到的预设会话、预设来信和预设群聊。
        </p>
      </header>

      <section className="space-y-4">
        <h2 className="text-lg font-semibold">预设会话</h2>
        <div className="space-y-4">
          {(conversations ?? []).map((row) => (
            <PresetConversationForm key={row.slug} row={row} />
          ))}
          <PresetConversationForm
            row={{
              slug: '',
              bot_slug: '',
              title: '',
              base_ts: '1970-01-01T00:00:00.000Z',
              messages: [],
              sort_order: 100,
              enabled: true,
            }}
          />
        </div>
      </section>

      <section className="space-y-4">
        <h2 className="text-lg font-semibold">预设群聊</h2>
        <div className="space-y-4">
          {(groups ?? []).map((row) => (
            <PresetGroupForm key={row.slug} row={row} />
          ))}
          <PresetGroupForm
            row={{
              slug: '',
              title: '',
              bot_slugs: [],
              join_policy: 'approval',
              messages: [],
              sort_order: 100,
              enabled: true,
            }}
          />
        </div>
      </section>

      <section className="space-y-4">
        <div>
          <h2 className="text-lg font-semibold">预设来信</h2>
          {letter && (
            <p className="text-xs text-muted-foreground">
              v{letter.version}，更新于{' '}
              {new Date(letter.updated_at).toLocaleString('zh-CN')}
            </p>
          )}
        </div>
        <LetterEditor
          initialTitle={letter?.title ?? ''}
          initialSummary={letter?.summary ?? ''}
          initialBody={letter?.body_md ?? ''}
        />
      </section>
    </main>
  );
}
