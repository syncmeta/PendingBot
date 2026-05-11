'use client';

import { useActionState, useState } from 'react';
import {
  pullUpstreamPrices,
  applyUpstreamPrices,
  type PullState,
  type ApplyState,
} from './actions';
import type { AliasDiffRow } from '@/lib/upstream-prices';
import {
  useFormErrorToast,
  useFormToast,
} from '@/components/use-form-error-toast';

// Client component owning the pull→diff→apply lifecycle. Two server
// actions back the two buttons:
//   - "拉取" calls pullUpstreamPrices, gets back rows + fetchedAt, stores
//     them in useActionState's state — no DB writes happen here.
//   - "应用所选" calls applyUpstreamPrices, takes the snapshot the user
//     literally saw on screen (encoded into hidden inputs per row) +
//     the checkbox set, writes those exact values to
//     llm_model_aliases. We deliberately don't re-fetch upstream on
//     apply so the admin's confirmation maps to what they reviewed.

export function DiffTable() {
  const [pullState, runPull, pullPending] = useActionState<PullState, FormData>(
    pullUpstreamPrices,
    { ok: false },
  );
  const [applyState, runApply, applyPending] = useActionState<ApplyState, FormData>(
    applyUpstreamPrices,
    { ok: false },
  );

  // Pull just needs an error surface — success is communicated by the
  // diff table itself rendering. Apply gets a full success toast with
  // counts so the admin doesn't have to re-read the inline summary.
  useFormErrorToast(pullState.error);
  useFormToast(
    applyState,
    applyState.ok
      ? `已写入 ${applyState.appliedCount ?? 0} 条${applyState.skippedCount ? ` · 跳过 ${applyState.skippedCount}` : ''}`
      : '已写入',
    applyState.ok
      ? `${applyState.appliedCount}|${applyState.skippedCount}`
      : undefined,
  );

  const rows = pullState.rows ?? [];
  const changedRows = rows.filter((r) => r.upstream && r.note == null);

  return (
    <div className="space-y-4">
      <form
        action={runPull}
        className="flex flex-wrap items-center gap-3 rounded-lg border bg-card px-4 py-3"
      >
        <span className="text-xs uppercase tracking-wide text-muted-foreground">
          上游价格
        </span>
        <button
          type="submit"
          disabled={pullPending}
          className="rounded-md bg-primary px-3 py-1 text-xs font-medium text-primary-foreground disabled:opacity-50"
        >
          {pullPending ? '拉取中…' : pullState.rows ? '重新拉取' : '拉取'}
        </button>
        {pullState.fetchedAt && (
          <span className="text-[11px] text-muted-foreground">
            最后拉取 {new Date(pullState.fetchedAt).toLocaleString()}
          </span>
        )}
        {pullState.error && (
          <span className="text-xs text-destructive">{pullState.error}</span>
        )}
        <span className="ml-auto text-[11px] text-muted-foreground">
          拉取不修改任何数据，确认后才会写库
        </span>
      </form>

      {pullState.rows && (
        <>
          <Summary
            total={rows.length}
            changed={changedRows.length}
            applyState={applyState}
          />
          <DiffForm
            rows={rows}
            action={runApply}
            pending={applyPending}
          />
        </>
      )}
    </div>
  );
}

function Summary({
  total,
  changed,
  applyState,
}: {
  total: number;
  changed: number;
  applyState: ApplyState;
}) {
  return (
    <div className="flex flex-wrap items-center gap-3 text-sm">
      <span>
        共 <span className="font-medium tabular-nums">{total}</span> 条 alias
      </span>
      <span className="text-muted-foreground">·</span>
      <span>
        与上游有差异：
        <span className="ml-1 font-medium tabular-nums text-amber-700">
          {changed}
        </span>
      </span>
      {applyState.ok && (applyState.appliedCount ?? 0) > 0 && (
        <span className="ml-auto text-xs text-emerald-700">
          已写入 {applyState.appliedCount} 条
          {applyState.skippedCount ? ` · 跳过 ${applyState.skippedCount}` : ''}
        </span>
      )}
      {applyState.error && (
        <span className="ml-auto text-xs text-destructive">
          {applyState.error}
        </span>
      )}
    </div>
  );
}

function DiffForm({
  rows,
  action,
  pending,
}: {
  rows: AliasDiffRow[];
  action: (formData: FormData) => void | Promise<void>;
  pending: boolean;
}) {
  // Local checkbox state — start with all "changed" rows pre-checked
  // so the common "apply everything that moved" case is one click.
  const initialChecked = new Set(
    rows.filter((r) => r.upstream && r.note == null).map((r) => r.aliasId),
  );
  const [checked, setChecked] = useState<Set<string>>(initialChecked);

  const toggle = (aliasId: string) => {
    setChecked((prev) => {
      const next = new Set(prev);
      if (next.has(aliasId)) next.delete(aliasId);
      else next.add(aliasId);
      return next;
    });
  };

  const selectAllChanged = () => {
    setChecked(
      new Set(
        rows.filter((r) => r.upstream && r.note == null).map((r) => r.aliasId),
      ),
    );
  };
  const selectNone = () => setChecked(new Set());

  return (
    <form action={action} className="space-y-3">
      <div className="flex items-center gap-2 text-xs">
        <button
          type="button"
          onClick={selectAllChanged}
          className="rounded border border-input px-2 py-1 hover:bg-accent"
        >
          全选有差异
        </button>
        <button
          type="button"
          onClick={selectNone}
          className="rounded border border-input px-2 py-1 hover:bg-accent"
        >
          全不选
        </button>
        <span className="ml-2 text-muted-foreground">
          已勾选 <span className="tabular-nums">{checked.size}</span> /{' '}
          {rows.length}
        </span>
      </div>

      <div className="overflow-x-auto rounded-lg border bg-card">
        <table className="w-full text-xs">
          <thead className="border-b text-left uppercase text-muted-foreground">
            <tr>
              <th className="w-10 px-3 py-2" />
              <th className="px-3 py-2 font-medium">model</th>
              <th className="px-3 py-2 font-medium">provider</th>
              <th className="px-3 py-2 font-medium">input</th>
              <th className="px-3 py-2 font-medium">cached_input</th>
              <th className="px-3 py-2 font-medium">output</th>
              <th className="px-3 py-2 font-medium">cache_write</th>
              <th className="px-3 py-2 font-medium">备注</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <DiffRow
                key={r.aliasId}
                row={r}
                checked={checked.has(r.aliasId)}
                onToggle={() => toggle(r.aliasId)}
              />
            ))}
            {rows.length === 0 && (
              <tr>
                <td
                  colSpan={8}
                  className="px-3 py-6 text-center text-muted-foreground"
                >
                  没有启用的 alias。
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      <div className="flex items-center gap-3">
        <button
          type="submit"
          disabled={pending || checked.size === 0}
          className="rounded-md bg-primary px-4 py-1.5 text-sm font-medium text-primary-foreground disabled:opacity-50"
        >
          {pending ? '写入中…' : `应用所选 (${checked.size})`}
        </button>
        <span className="text-xs text-muted-foreground">
          写入的是你现在看到的快照——不会再拉一次上游
        </span>
      </div>
    </form>
  );
}

function DiffRow({
  row,
  checked,
  onToggle,
}: {
  row: AliasDiffRow;
  checked: boolean;
  onToggle: () => void;
}) {
  const hasUpstream = row.upstream != null;
  const canApply = hasUpstream && row.note == null;
  const payload = hasUpstream
    ? JSON.stringify({ v: 1, ...row.upstream })
    : '';
  return (
    <tr className="border-b align-top last:border-0">
      <td className="px-3 py-2">
        <input
          type="checkbox"
          name="apply"
          value={row.aliasId}
          checked={checked}
          onChange={onToggle}
          disabled={!canApply}
          className="h-4 w-4"
        />
        {hasUpstream && (
          <input type="hidden" name={`payload:${row.aliasId}`} value={payload} />
        )}
      </td>
      <td className="px-3 py-2 font-mono">
        <div>{row.modelSlug}</div>
        <div className="text-[10px] text-muted-foreground">
          {row.modelDisplayName}
        </div>
      </td>
      <td className="px-3 py-2 font-mono">
        <div>{row.providerSlug}</div>
        <div className="text-[10px] text-muted-foreground">
          {row.providerModelId}
        </div>
      </td>
      <PriceCell
        current={row.current.input_price}
        upstream={row.upstream?.input_price ?? null}
        changed={row.changed.input_price}
      />
      <PriceCell
        current={row.current.cached_input_price}
        upstream={row.upstream?.cached_input_price ?? null}
        changed={row.changed.cached_input_price}
      />
      <PriceCell
        current={row.current.output_price}
        upstream={row.upstream?.output_price ?? null}
        changed={row.changed.output_price}
      />
      <PriceCell
        current={row.current.cache_write_price}
        upstream={row.upstream?.cache_write_price ?? null}
        changed={row.changed.cache_write_price}
      />
      <td className="px-3 py-2 text-[11px] text-muted-foreground">
        {row.note ?? (hasUpstream && !canApply ? '—' : '')}
      </td>
    </tr>
  );
}

function PriceCell({
  current,
  upstream,
  changed,
}: {
  current: number | null;
  upstream: number | null;
  changed: boolean;
}) {
  return (
    <td className="px-3 py-2 tabular-nums">
      <div className="text-muted-foreground">{fmt(current)}</div>
      {upstream != null ? (
        <div
          className={
            changed ? 'font-medium text-amber-700' : 'text-muted-foreground/70'
          }
        >
          → {fmt(upstream)}
        </div>
      ) : (
        <div className="text-muted-foreground/50">—</div>
      )}
    </td>
  );
}

function fmt(v: number | null): string {
  if (v == null) return '—';
  // 4 decimals is enough resolution for per-million-token USD prices
  // (the column stores 6 but the diff UI prioritizes scanability).
  return v.toFixed(4);
}
