import { useList, useUpdate } from '@refinedev/core';
import { PendingBanner } from './common';
import { RESOURCE_ROUTES } from '../providers/resource-map';

// 7a. Human-help-request queue. EXISTING edge route GET /v1/human-help-requests
// (?status=pending) — requester-scoped. Decision via
// POST /v1/human-help-requests/:id/decision { decision: accepted|declined }
// (wired through dataProvider.update for resource 'human_help_requests').
export const HumanHelpQueue = () => {
  const { result, query } = useList({
    resource: 'human_help_requests',
    filters: [{ field: 'status', operator: 'eq', value: 'pending' }],
  });
  const { mutate } = useUpdate();
  const rows = (result?.data ?? []) as Record<string, unknown>[];

  const decide = (id: string, decision: 'accepted' | 'declined') =>
    mutate({ resource: 'human_help_requests', id, values: { decision } });

  return (
    <div>
      <h2>人工协助请求（待处理）</h2>
      {query.isError ? (
        <div style={{ color: '#b00020' }}>
          {(query.error as { message?: string })?.message}
        </div>
      ) : null}
      <table style={{ borderCollapse: 'collapse', width: '100%', fontSize: 13 }}>
        <thead>
          <tr>
            <th style={th}>ID</th>
            <th style={th}>群</th>
            <th style={th}>请求者</th>
            <th style={th}>原因</th>
            <th style={th}>时间</th>
            <th style={th}>操作</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => {
            const tg = (r.temporary_group ?? {}) as Record<string, unknown>;
            const requester = (r.requester ?? {}) as Record<string, unknown>;
            return (
              <tr key={r.id as string}>
                <td style={td}>{String(r.id ?? '')}</td>
                <td style={td}>{String(tg.title ?? '')}</td>
                <td style={td}>{String(requester.display_name ?? '')}</td>
                <td style={td}>{String(r.reason ?? '')}</td>
                <td style={td}>{String(r.created_at ?? '')}</td>
                <td style={td}>
                  <button onClick={() => decide(r.id as string, 'accepted')}>接受</button>{' '}
                  <button onClick={() => decide(r.id as string, 'declined')}>拒绝</button>
                </td>
              </tr>
            );
          })}
          {rows.length === 0 && !query.isLoading ? (
            <tr>
              <td colSpan={6} style={{ padding: 12, opacity: 0.6 }}>
                无待处理请求
              </td>
            </tr>
          ) : null}
        </tbody>
      </table>
    </div>
  );
};

// 7b. Permission-request approvals. DECIDE action EXISTS
// (POST /v1/permission-requests/:id/decide { decision: approve|reject }).
// The LIST is PENDING (no /v1/admin/permission-requests yet) — banner shown.
export const PermissionRequestQueue = () => {
  const { result, query } = useList({ resource: 'permission_requests' });
  const { mutate } = useUpdate();
  const rows = (result?.data ?? []) as Record<string, unknown>[];

  const decide = (id: string, decision: 'approve' | 'reject') =>
    mutate({ resource: 'permission_requests', id, values: { decision } });

  return (
    <div>
      <h2>权限审批</h2>
      {!RESOURCE_ROUTES.permission_requests.exists ? (
        <PendingBanner note={RESOURCE_ROUTES.permission_requests.note} />
      ) : null}
      {query.isError ? (
        <div style={{ color: '#b00020' }}>
          {(query.error as { message?: string })?.message}
        </div>
      ) : null}
      <table style={{ borderCollapse: 'collapse', width: '100%', fontSize: 13 }}>
        <thead>
          <tr>
            <th style={th}>ID</th>
            <th style={th}>动作</th>
            <th style={th}>风险</th>
            <th style={th}>状态</th>
            <th style={th}>操作</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.id as string}>
              <td style={td}>{String(r.id ?? '')}</td>
              <td style={td}>{String(r.requested_action ?? '')}</td>
              <td style={td}>{String(r.risk_level ?? '')}</td>
              <td style={td}>{String(r.status ?? '')}</td>
              <td style={td}>
                <button onClick={() => decide(r.id as string, 'approve')}>批准</button>{' '}
                <button onClick={() => decide(r.id as string, 'reject')}>驳回</button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
};

const th: React.CSSProperties = {
  textAlign: 'left',
  borderBottom: '2px solid #ddd',
  padding: '6px 8px',
};
const td: React.CSSProperties = { borderBottom: '1px solid #eee', padding: '6px 8px' };
