import Link from 'next/link';
import { supabaseAdmin } from '@/lib/supabase/admin';
import { ActionButton } from '@/components/action-button';
import { toggleMcpServerEnabled, deleteMcpServer } from './actions';

// MCP server registry — backs apps/edge/src/mcp/client.ts which reads
// this table on a 60s isolate cache. Saved changes take effect on the
// next worker isolate that refreshes its cache (within ~1 min).
export default async function McpServersPage() {
  const supa = supabaseAdmin();
  const { data: rows } = await supa
    .from('mcp_servers')
    .select(
      'id, name, url, transport, auth_kind, auth_header_name, secret_ref, enabled, notes, last_health_check_at, last_health_error, updated_at',
    )
    .order('name', { ascending: true });

  const servers = rows ?? [];

  return (
    <main className="container py-10 space-y-6">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">MCP servers</h1>
          <p className="text-sm text-muted-foreground">
            Worker 上 MCP client 连接的上游服务。新增 = 表里插一行 + Wrangler 上把对应
            secret 推上去；密钥本体不入库。
          </p>
        </div>
        <Link
          href="/mcp-servers/new"
          className="rounded-md bg-primary px-3 py-1.5 text-sm font-medium text-primary-foreground"
        >
          新增 MCP 服务
        </Link>
      </header>

      <div className="overflow-x-auto rounded-lg border bg-card">
        <table className="w-full text-sm">
          <thead className="border-b text-left text-xs uppercase text-muted-foreground">
            <tr>
              <th className="px-4 py-2 font-medium">name</th>
              <th className="px-4 py-2 font-medium">url</th>
              <th className="px-4 py-2 font-medium">transport</th>
              <th className="px-4 py-2 font-medium">auth</th>
              <th className="px-4 py-2 font-medium">状态</th>
              <th className="px-4 py-2 font-medium" />
            </tr>
          </thead>
          <tbody>
            {servers.map((s) => (
              <tr key={s.id} className="border-b align-top last:border-0">
                <td className="px-4 py-3 font-mono text-xs">
                  {s.name}
                  {s.notes && (
                    <div className="mt-1 text-[10px] font-sans text-muted-foreground">
                      {s.notes}
                    </div>
                  )}
                </td>
                <td className="px-4 py-3 font-mono text-xs text-muted-foreground">{s.url}</td>
                <td className="px-4 py-3 text-xs">{s.transport}</td>
                <td className="px-4 py-3 font-mono text-xs">
                  {s.auth_kind === 'none' ? (
                    <span className="text-muted-foreground">none</span>
                  ) : (
                    <>
                      <div>{s.auth_header_name}</div>
                      <div className="text-[10px] text-muted-foreground">
                        ← env.{s.secret_ref}
                      </div>
                    </>
                  )}
                </td>
                <td className="px-4 py-3">
                  {s.enabled ? (
                    <span className="rounded bg-emerald-100 px-2 py-0.5 text-xs text-emerald-700">
                      enabled
                    </span>
                  ) : (
                    <span className="rounded bg-muted px-2 py-0.5 text-xs text-muted-foreground">
                      disabled
                    </span>
                  )}
                  {s.last_health_error && (
                    <div className="mt-1 text-[10px] text-amber-700">
                      last error: {s.last_health_error}
                    </div>
                  )}
                </td>
                <td className="px-4 py-3">
                  <div className="flex items-center justify-end gap-2">
                    <Link
                      href={`/mcp-servers/${s.id}`}
                      className="rounded border border-input px-2 py-1 text-xs hover:bg-accent"
                    >
                      编辑
                    </Link>
                    <ActionButton
                      action={toggleMcpServerEnabled}
                      args={[s.id]}
                      size="sm"
                      label={s.enabled ? '停用' : '启用'}
                      pendingLabel={s.enabled ? '停用中…' : '启用中…'}
                    />
                    <ActionButton
                      action={deleteMcpServer}
                      args={[s.id]}
                      size="sm"
                      variant="destructive"
                      label="删除"
                      pendingLabel="删除中…"
                      confirmText={`确定删除 MCP 服务 ${s.name}？正在使用该服务工具的对话会失败直到下个 isolate 刷新缓存。`}
                    />
                  </div>
                </td>
              </tr>
            ))}
            {servers.length === 0 && (
              <tr>
                <td colSpan={6} className="px-4 py-8 text-center text-muted-foreground">
                  还没有 MCP 服务。点右上方"新增"开始。
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      <p className="text-xs text-muted-foreground">
        Edge worker 用 60s 缓存读这张表（apps/edge/src/mcp/client.ts），保存后下个 isolate
        周期生效。<code className="font-mono">secret_ref</code> 是 Wrangler 上的 env var 名——
        添加新 server 前先 <code>wrangler secret put 该名字</code>，并把它加进
        <code className="font-mono">apps/edge/src/types.ts</code> 的 Env 接口，否则 worker 连不上去。
      </p>
    </main>
  );
}
