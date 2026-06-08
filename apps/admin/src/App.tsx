import { Refine, Authenticated } from '@refinedev/core';
import { ThemedLayout, RefineThemes, useNotificationProvider } from '@refinedev/antd';
import routerProvider, { NavigateToResource, CatchAllNavigate } from '@refinedev/react-router';
import { BrowserRouter, Routes, Route, Outlet } from 'react-router';
import { ConfigProvider, App as AntdApp } from 'antd';
import '@refinedev/antd/dist/reset.css';

import { dataProvider } from './providers/data-provider';
import { authProvider } from './providers/auth-provider';
import { LoginPage } from './pages/login';
import { PresetBotList, PresetBotCreate, PresetBotEdit } from './pages/preset-bots';
import { FeatureFlagsPage } from './pages/feature-flags';

export default function App() {
  return (
    <BrowserRouter>
      <ConfigProvider theme={RefineThemes.Blue}>
        <AntdApp>
          <Refine
            routerProvider={routerProvider}
            dataProvider={dataProvider}
            authProvider={authProvider}
            notificationProvider={useNotificationProvider}
            options={{ disableTelemetry: true, warnWhenUnsavedChanges: true }}
            resources={[
              {
                name: 'preset_bots',
                list: '/preset-bots',
                create: '/preset-bots/create',
                edit: '/preset-bots/edit/:id',
                meta: { label: '预设机器人' },
              },
              {
                name: 'feature_flags',
                list: '/feature-flags',
                meta: { label: '功能开关' },
              },
            ]}
          >
            <Routes>
              <Route path="/login" element={<LoginPage />} />
              <Route
                element={
                  <Authenticated key="protected" fallback={<CatchAllNavigate to="/login" />}>
                    <ThemedLayout Title={() => <strong>PendingBot Board</strong>}>
                      <Outlet />
                    </ThemedLayout>
                  </Authenticated>
                }
              >
                <Route index element={<NavigateToResource resource="preset_bots" />} />
                <Route path="/preset-bots" element={<PresetBotList />} />
                <Route path="/preset-bots/create" element={<PresetBotCreate />} />
                <Route path="/preset-bots/edit/:id" element={<PresetBotEdit />} />
                <Route path="/feature-flags" element={<FeatureFlagsPage />} />
              </Route>
              <Route path="*" element={<CatchAllNavigate to="/login" />} />
            </Routes>
          </Refine>
        </AntdApp>
      </ConfigProvider>
    </BrowserRouter>
  );
}
