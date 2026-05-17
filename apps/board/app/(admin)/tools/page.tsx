import Link from 'next/link';
import { supabaseAdmin } from '@/lib/supabase/admin';
import { ActionButton } from '@/components/action-button';
import { toggleToolEnabled, deleteTool } from './actions';

// Tools registry — every LLM tool the bot can be advertised, native
// + MCP, in one place. Edge filters its advertised tool list against
// rows here (apps/edge/src/lib/tools-registry.ts, 60s isolate cache).
// Toggling a row off pulls the tool out of the model surface within
// ~1 min, no deploy.
//
// Rows are CRUD-managed from this page (new / edit / delete). For
// native tools the runtime implementation still lives in edge code
// (apps/edge/src/lib/bot-reply/tools/*) — this table is the filter +
// metadata layer, not a dispatcher.

interface ToolRow {
  id: string;
  key: string;
  kind: 'native' | 'mcp' | string;
  mcp_server_id: string | null;
  scopes: unknown;
  description: string | null;
  enabled: boolean;
  notes: string | null;
}

function asScopes(v: unknown): string[] {
  return Array.isArray(v) ? (v as unknown[]).filter((s): s is string => typeof s === 'string') : [];
}

export default async function ToolsPage() {
  const supa = supabaseAdmin();
  const [toolsRes, serversRes] = await Promise.all([
    supa
      .from('tools')
      .select('id, key, kind, mcp_server_id, scopes, description, enabled, notes')
      .order('kind', { ascending: true })
      .order('key', { ascending: true }),
    supa.from('mcp_servers').select('id, name'),
  ]);

  const rows = (toolsRes.data ?? []) as unknown as ToolRow[];
  const serverNameById = new Map<string, string>();
  for (const s of serversRes.data ?? []) serverNameById.set(s.id, s.name);

  const nativeRows = rows.filter((r) => r.kind === 'native');
  const mcpByServer = new Map<string, ToolRow[]>();
  for (const r of rows.filter((r) => r.kind === 'mcp')) {
    const key = r.mcp_server_id ?? 'unknown';
    const arr = mcpByServer.get(key) ?? [];
    arr.push(r);
    mcpByServer.set(key, arr);
  }

  return (
    <main className="container py-10 space-y-8">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">Tools</h1>
          <p className="text-sm text-muted-foreground">
            模型能用的全部工具——内部代码工具 + 来自 MCP server 的工具。停用一行 = 模型不再
            被告知有这个工具（worker 60s isolate 缓存生效），不需要部署。
          </p>
        </div>
        <Link
          href="/tools/new"
          className="rounded-md bg-primary px-3 py-1.5 text-sm font-medium text-primary-foreground"
        >
          新增工具
        </Link>
      </header>

      <Section title="Native (代码实现)" rows={nativeRows} />

      {[...mcpByServer.entries()].map(([serverId, tools]) => (
        <Section
          key={serverId}
          title={`MCP — ${serverNameById.get(serverId) ?? `${serverId.slice(0, 8)}…`}`}
          rows={tools}
        />
      ))}

      <p className="text-xs text-muted-foreground">
        新加 native 工具：代码里写实现，再点右上"新增工具"登记一行。新加 MCP 工具：先去
        MCP servers 页接好上游，再来这里"新增工具"挑暴露哪个 upstream tool。
        <code className="font-mono">scopes</code> 决定工具出现在 chat / envelope / 二者皆有。
      </p>
    </main>
  );
}

function Section({ title, rows }: { title: string; rows: ToolRow[] }) {
  if (rows.length === 0) return null;
  return (
    <section className="space-y-3">
      <h2 className="text-lg font-semibold tracking-tight">{title}</h2>
      <div className="overflow-x-auto rounded-lg border bg-card">
        <table className="w-full text-sm">
          <thead className="border-b text-left text-xs uppercase text-muted-foreground">
            <tr>
              <th className="px-4 py-2 font-medium">key</th>
              <th className="px-4 py-2 font-medium">scope</th>
              <th className="px-4 py-2 font-medium">说明</th>
              <th className="px-4 py-2 font-medium">状态</th>
              <th className="px-4 py-2 font-medium" />
            </tr>
          </thead>
          <tbody>
            {rows.map((t) => {
              const scopes = asScopes(t.scopes);
              return (
                <tr key={t.id} className="border-b align-top last:border-0">
                  <td className="px-4 py-3 font-mono text-xs">{t.key}</td>
                  <td className="px-4 py-3">
                    <div className="flex flex-wrap gap-1">
                      {scopes.map((s) => (
                        <span
                          key={s}
                          className="rounded bg-muted px-1.5 py-0.5 font-mono text-[10px]"
                        >
                          {s}
                        </span>
                      ))}
                    </div>
                  </td>
                  <td className="px-4 py-3 text-xs text-muted-foreground">
                    {t.description ?? '—'}
                  </td>
                  <td className="px-4 py-3">
                    {t.enabled ? (
                      <span className="rounded bg-emerald-100 px-2 py-0.5 text-xs text-emerald-700">
                        enabled
                      </span>
                    ) : (
                      <span className="rounded bg-muted px-2 py-0.5 text-xs text-muted-foreground">
                        disabled
                      </span>
                    )}
                  </td>
                  <td className="px-4 py-3">
                    <div className="flex items-center justify-end gap-2">
                      <Link
                        href={`/tools/${t.id}`}
                        className="rounded border border-input px-2 py-1 text-xs hover:bg-accent"
                      >
                        编辑
                      </Link>
                      <ActionButton
                        action={toggleToolEnabled}
                        args={[t.id]}
                        size="sm"
                        label={t.enabled ? '停用' : '启用'}
                        pendingLabel={t.enabled ? '停用中…' : '启用中…'}
                      />
                      <ActionButton
                        action={deleteTool}
                        args={[t.id]}
                        size="sm"
                        variant="destructive"
                        label="删除"
                        pendingLabel="删除中…"
                        confirmText={`确定删除工具 ${t.key}？删掉后模型不再被告知有这个工具（下个 isolate 周期生效）。`}
                      />
                    </div>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </section>
  );
}
