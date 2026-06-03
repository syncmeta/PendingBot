import { useState } from 'react';
import { useCustomMutation } from '@refinedev/core';
import { ADMIN_ACTION_ENDPOINTS } from '../providers/data-provider';
import { EDGE_API_URL } from '../env';
import { PendingBanner } from './common';

// 6. Admin write actions — wallet grant / claw-back, ledger adjustment,
// account ops. ALL POST to edge admin endpoints that DO NOT EXIST YET
// (ADMIN_ACTION_ENDPOINTS, all exists:false). Wired to the intended paths via
// useCustomMutation so the page works the moment the endpoints land. Until
// then a submit returns 404 — surfaced honestly, no fake success. Gaps logged
// to docs/tech-debt.md.

function ActionForm({
  title,
  endpoint,
  fields,
}: {
  title: string;
  endpoint: { method: 'POST'; path: string; exists: boolean };
  fields: { name: string; label: string; placeholder?: string }[];
}) {
  const [values, setValues] = useState<Record<string, string>>({});
  const { mutate, mutation } = useCustomMutation();

  const submit = () => {
    // Coerce delta_credits to a number if present.
    const payload: Record<string, unknown> = { ...values };
    if (typeof payload.delta_credits === 'string') {
      payload.delta_credits = Number(payload.delta_credits);
    }
    mutate({
      url: `${EDGE_API_URL}/v1/${endpoint.path}`,
      method: endpoint.method.toLowerCase() as 'post',
      values: payload,
    });
  };

  return (
    <fieldset style={{ border: '1px solid #ddd', borderRadius: 8, padding: 16, marginBottom: 20 }}>
      <legend style={{ fontWeight: 600 }}>{title}</legend>
      {!endpoint.exists ? (
        <PendingBanner note={`目标端点 POST /v1/${endpoint.path} 尚未实现。`} />
      ) : null}
      {fields.map((f) => (
        <div key={f.name} style={{ marginBottom: 8 }}>
          <label style={{ display: 'inline-block', width: 140, fontSize: 13 }}>{f.label}</label>
          <input
            value={values[f.name] ?? ''}
            placeholder={f.placeholder}
            onChange={(e) => setValues((v) => ({ ...v, [f.name]: e.target.value }))}
            style={{ padding: '4px 8px', width: 280 }}
          />
        </div>
      ))}
      <button onClick={submit} disabled={mutation.isPending} style={{ marginTop: 8 }}>
        {mutation.isPending ? '提交中…' : '提交'}
      </button>
      {mutation.isError ? (
        <div style={{ color: '#b00020', marginTop: 8, fontSize: 13 }}>
          失败：{(mutation.error as { message?: string })?.message ?? '未知错误'}
        </div>
      ) : null}
      {mutation.isSuccess ? (
        <div style={{ color: '#0a7d33', marginTop: 8, fontSize: 13 }}>已提交</div>
      ) : null}
    </fieldset>
  );
}

export const AdminActions = () => (
  <div>
    <h2>管理操作（写入，经 edge）</h2>
    <p style={{ fontSize: 13, opacity: 0.75 }}>
      所有写入都经过 edge 校验与审计（admin_audit）。前端不持有 service-role key。
    </p>
    <ActionForm
      title="钱包充值 / 发放额度"
      endpoint={ADMIN_ACTION_ENDPOINTS.walletGrant}
      fields={[
        { name: 'subject_id', label: 'Subject ID', placeholder: 'uuid（或填 user_id）' },
        { name: 'user_id', label: 'User ID', placeholder: 'uuid（二选一）' },
        { name: 'delta_credits', label: 'Credits (+)', placeholder: '正整数' },
        { name: 'reason', label: '原因', placeholder: '必填，进 admin_audit' },
      ]}
    />
    <ActionForm
      title="钱包回收（claw-back）"
      endpoint={ADMIN_ACTION_ENDPOINTS.walletClawback}
      fields={[
        { name: 'subject_id', label: 'Subject ID' },
        { name: 'user_id', label: 'User ID' },
        { name: 'delta_credits', label: 'Credits (回收量)', placeholder: '正整数；后端取负' },
        { name: 'reason', label: '原因' },
      ]}
    />
    <ActionForm
      title="台账调整（billing_ledger adjustment）"
      endpoint={ADMIN_ACTION_ENDPOINTS.ledgerAdjust}
      fields={[
        { name: 'user_id', label: 'User ID' },
        { name: 'subject_id', label: 'Subject ID' },
        { name: 'delta_credits', label: 'Δ Credits' },
        { name: 'entry_type', label: 'entry_type', placeholder: 'topup|refund|adjustment' },
        { name: 'reason', label: '原因' },
      ]}
    />
    <ActionForm
      title="账户操作"
      endpoint={ADMIN_ACTION_ENDPOINTS.accountOp}
      fields={[
        { name: 'user_id', label: 'User ID' },
        { name: 'op', label: '操作', placeholder: 'freeze|unfreeze|delete' },
        { name: 'reason', label: '原因' },
      ]}
    />
  </div>
);
