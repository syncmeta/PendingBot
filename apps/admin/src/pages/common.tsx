import type { ReactNode } from 'react';
import { useList, useOne } from '@refinedev/core';

// Tiny headless table/detail primitives. The dashboard spec did not mandate a
// UI kit; this keeps the bundle small and the wiring obvious. Swap for Ant
// Design / MUI later if richer interactions are needed.

export function PendingBanner({ note }: { note?: string }) {
  return (
    <div
      style={{
        background: '#fff8e1',
        border: '1px solid #f0c36d',
        borderRadius: 6,
        padding: '8px 12px',
        margin: '8px 0',
        fontSize: 13,
        color: '#664d03',
      }}
    >
      ⚠ 此资源依赖的 edge admin 端点尚未实现（见 docs/tech-debt.md）。当前调用会返回 404。
      {note ? <div style={{ marginTop: 4, opacity: 0.8 }}>{note}</div> : null}
    </div>
  );
}

type Col = { key: string; label: string; render?: (row: Record<string, unknown>) => ReactNode };

export function ResourceTable({
  resource,
  columns,
  pendingNote,
  filters,
}: {
  resource: string;
  columns: Col[];
  pendingNote?: string;
  filters?: { field: string; operator: 'eq'; value: unknown }[];
}) {
  const { result, query } = useList({
    resource,
    pagination: { pageSize: 50 },
    filters,
  });
  const rows = (result?.data ?? []) as Record<string, unknown>[];

  return (
    <div>
      {pendingNote ? <PendingBanner note={pendingNote} /> : null}
      {query.isError ? (
        <div style={{ color: '#b00020', padding: 8 }}>
          加载失败：{(query.error as { message?: string })?.message ?? '未知错误'}
        </div>
      ) : null}
      <table style={{ borderCollapse: 'collapse', width: '100%', fontSize: 13 }}>
        <thead>
          <tr>
            {columns.map((c) => (
              <th
                key={c.key}
                style={{ textAlign: 'left', borderBottom: '2px solid #ddd', padding: '6px 8px' }}
              >
                {c.label}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((row, i) => (
            <tr key={(row.id as string) ?? i}>
              {columns.map((c) => (
                <td key={c.key} style={{ borderBottom: '1px solid #eee', padding: '6px 8px' }}>
                  {c.render ? c.render(row) : String(row[c.key] ?? '')}
                </td>
              ))}
            </tr>
          ))}
          {rows.length === 0 && !query.isLoading ? (
            <tr>
              <td colSpan={columns.length} style={{ padding: 12, opacity: 0.6 }}>
                无数据
              </td>
            </tr>
          ) : null}
        </tbody>
      </table>
      {query.isLoading ? <div style={{ padding: 8 }}>加载中…</div> : null}
    </div>
  );
}

export function ResourceShow({ resource, id }: { resource: string; id: string }) {
  const { result, query } = useOne({ resource, id });
  const record = (result?.data ?? null) as Record<string, unknown> | null;
  return (
    <div>
      {query.isError ? (
        <div style={{ color: '#b00020', padding: 8 }}>
          加载失败：{(query.error as { message?: string })?.message ?? '未知错误'}
        </div>
      ) : null}
      {record ? (
        <pre style={{ background: '#f6f8fa', padding: 12, borderRadius: 6, overflow: 'auto' }}>
          {JSON.stringify(record, null, 2)}
        </pre>
      ) : query.isLoading ? (
        <div style={{ padding: 8 }}>加载中…</div>
      ) : (
        <div style={{ padding: 8, opacity: 0.6 }}>无数据</div>
      )}
    </div>
  );
}
