import { Refine, Authenticated } from '@refinedev/core';
import routerProvider, {
  NavigateToResource,
  CatchAllNavigate,
} from '@refinedev/react-router';
import { BrowserRouter, Routes, Route, Outlet, Link } from 'react-router';

import { dataProvider } from './providers/data-provider';
import { authProvider } from './providers/auth-provider';
import { LoginPage } from './pages/login';
import {
  UserList,
  UserShow,
  BotList,
  BotShow,
  ConversationList,
  ConversationShow,
  BillingLedgerList,
  GroupPoolList,
} from './pages/resources';
import { HumanHelpQueue, PermissionRequestQueue } from './pages/queues';
import { AdminActions } from './pages/admin-actions';

// Minimal authenticated shell with a nav sidebar. Every inner route is gated
// by <Authenticated> → unauthenticated users bounce to /login.
function Shell() {
  return (
    <div style={{ display: 'flex', minHeight: '100vh', fontFamily: 'system-ui, sans-serif' }}>
      <nav style={{ width: 200, borderRight: '1px solid #eee', padding: 16, fontSize: 14 }}>
        <strong>PendingBot Admin</strong>
        <ul style={{ listStyle: 'none', padding: 0, lineHeight: 2 }}>
          <li><Link to="/users">用户</Link></li>
          <li><Link to="/bots">Bots</Link></li>
          <li><Link to="/conversations">会话</Link></li>
          <li><Link to="/billing_ledger">计费台账</Link></li>
          <li><Link to="/group_pool">群池/分摊</Link></li>
          <li><Link to="/human_help_requests">人工协助</Link></li>
          <li><Link to="/permission_requests">权限审批</Link></li>
          <li><Link to="/admin-actions">管理操作</Link></li>
        </ul>
      </nav>
      <main style={{ flex: 1, padding: 24 }}>
        <Outlet />
      </main>
    </div>
  );
}

export default function App() {
  return (
    <BrowserRouter>
      <Refine
        routerProvider={routerProvider}
        dataProvider={dataProvider}
        authProvider={authProvider}
        options={{ disableTelemetry: true, warnWhenUnsavedChanges: true }}
        resources={[
          { name: 'users', list: '/users', show: '/users/show/:id', meta: { label: '用户' } },
          { name: 'bots', list: '/bots', show: '/bots/show/:id', meta: { label: 'Bots' } },
          {
            name: 'conversations',
            list: '/conversations',
            show: '/conversations/show/:id',
            meta: { label: '会话' },
          },
          { name: 'billing_ledger', list: '/billing_ledger', meta: { label: '计费台账' } },
          { name: 'group_pool', list: '/group_pool', meta: { label: '群池/分摊' } },
          {
            name: 'human_help_requests',
            list: '/human_help_requests',
            meta: { label: '人工协助' },
          },
          {
            name: 'permission_requests',
            list: '/permission_requests',
            meta: { label: '权限审批' },
          },
        ]}
      >
        <Routes>
          <Route path="/login" element={<LoginPage />} />
          <Route
            element={
              <Authenticated key="protected" fallback={<CatchAllNavigate to="/login" />}>
                <Shell />
              </Authenticated>
            }
          >
            <Route index element={<NavigateToResource resource="users" />} />
            <Route path="/users" element={<UserList />} />
            <Route path="/users/show/:id" element={<UserShow />} />
            <Route path="/bots" element={<BotList />} />
            <Route path="/bots/show/:id" element={<BotShow />} />
            <Route path="/conversations" element={<ConversationList />} />
            <Route path="/conversations/show/:id" element={<ConversationShow />} />
            <Route path="/billing_ledger" element={<BillingLedgerList />} />
            <Route path="/group_pool" element={<GroupPoolList />} />
            <Route path="/human_help_requests" element={<HumanHelpQueue />} />
            <Route path="/permission_requests" element={<PermissionRequestQueue />} />
            <Route path="/admin-actions" element={<AdminActions />} />
          </Route>
          <Route path="*" element={<CatchAllNavigate to="/login" />} />
        </Routes>
      </Refine>
    </BrowserRouter>
  );
}
