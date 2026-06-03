import { useParams } from 'react-router';
import { ResourceTable, ResourceShow } from './common';
import { RESOURCE_ROUTES } from '../providers/resource-map';

// Read-only resource pages. Each list maps to its edge route via the
// dataProvider; pending ones show the banner. Columns reflect the real DB
// columns (apps/edge/src/db/schema.ts).

const pendingNote = (resource: string) =>
  RESOURCE_ROUTES[resource]?.exists ? undefined : RESOURCE_ROUTES[resource]?.note;

// 1. Users — id, handle, created_at, subject.
export const UserList = () => (
  <ResourceTable
    resource="users"
    pendingNote={pendingNote('users')}
    columns={[
      { key: 'id', label: 'ID' },
      { key: 'handle', label: 'Handle' },
      { key: 'display_name', label: '昵称' },
      { key: 'subject_id', label: '责任主体' },
      { key: 'is_admin', label: 'Admin', render: (r) => (r.is_admin ? '✓' : '') },
      { key: 'created_at', label: '创建时间' },
    ]}
  />
);
export const UserShow = () => {
  const { id } = useParams();
  return <ResourceShow resource="users" id={id ?? ''} />;
};

// 2. Bots — visibility, model, owner.
export const BotList = () => (
  <ResourceTable
    resource="bots"
    pendingNote={pendingNote('bots')}
    columns={[
      { key: 'id', label: 'ID' },
      { key: 'display_name', label: '名称' },
      { key: 'visibility', label: '可见性' },
      { key: 'model_id', label: '模型' },
      { key: 'creator_id', label: 'Owner' },
      { key: 'responsible_subject_id', label: '责任主体' },
      { key: 'is_active', label: '启用', render: (r) => (r.is_active ? '✓' : '') },
    ]}
  />
);
export const BotShow = () => {
  const { id } = useParams();
  return <ResourceShow resource="bots" id={id ?? ''} />;
};

// 3. Conversations.
export const ConversationList = () => (
  <ResourceTable
    resource="conversations"
    pendingNote={pendingNote('conversations')}
    columns={[
      { key: 'id', label: 'ID' },
      { key: 'title', label: '标题' },
      { key: 'conversation_type', label: '类型' },
      { key: 'bot_id', label: 'Bot' },
      { key: 'user_id', label: 'User' },
      { key: 'responsible_subject_id', label: '责任主体' },
      { key: 'updated_at', label: '更新时间' },
    ]}
  />
);
export const ConversationShow = () => {
  const { id } = useParams();
  return <ResourceShow resource="conversations" id={id ?? ''} />;
};

// 4. Billing ledger (pnc_ledger spec name → real billing_ledger).
export const BillingLedgerList = () => (
  <ResourceTable
    resource="billing_ledger"
    pendingNote={pendingNote('billing_ledger')}
    columns={[
      { key: 'id', label: 'ID' },
      { key: 'user_id', label: 'User' },
      { key: 'entry_type', label: '类型' },
      { key: 'delta_credits', label: 'Δ Credits' },
      { key: 'reason', label: '原因' },
      { key: 'created_at', label: '时间' },
    ]}
  />
);

// 5. Group pool / pledge view.
export const GroupPoolList = () => (
  <ResourceTable
    resource="group_pool"
    pendingNote={pendingNote('group_pool')}
    columns={[
      { key: 'conversation_id', label: '群会话' },
      { key: 'mode', label: '分摊模式' },
      { key: 'window_seconds', label: '窗口(s)' },
      { key: 'spent_credits', label: '已花费' },
      { key: 'cap_credits', label: '上限' },
      { key: 'user_id', label: '成员' },
    ]}
  />
);
