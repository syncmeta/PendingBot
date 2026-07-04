import { Refine } from '@refinedev/core';
import { ThemedLayout, RefineThemes, useNotificationProvider } from '@refinedev/antd';
import routerProvider, { NavigateToResource } from '@refinedev/react-router';
import { BrowserRouter, Routes, Route } from 'react-router';
import { ConfigProvider, App as AntdApp } from 'antd';
import '@refinedev/antd/dist/reset.css';

import { dataProvider } from './providers/data-provider';
import { PresetBotList, PresetBotCreate, PresetBotEdit } from './pages/preset-bots';
import {
  PresetConversationList,
  PresetConversationCreate,
  PresetConversationEdit,
} from './pages/preset-conversations';
import { PresetGroupList, PresetGroupCreate, PresetGroupEdit } from './pages/preset-groups';
import { PresetLetterList, PresetLetterCreate, PresetLetterEdit } from './pages/preset-letters';
import { ToolList, ToolEdit } from './pages/tools';
import { McpServerList, McpServerCreate, McpServerEdit } from './pages/mcp-servers';
import { ModelPresetList, ModelPresetCreate, ModelPresetEdit } from './pages/model-presets';
import { FeatureFlagsPage } from './pages/feature-flags';
import { ModelRolesPage } from './pages/model-roles';
import { BillingPacksPage } from './pages/billing-packs';
import { BillingWalletPage } from './pages/billing-wallet';

// No authProvider / login route: the board is served same-origin under /board
// behind Cloudflare Access, which is the sole identity gate (the edge verifies
// the Access JWT on /v1/board/*). The SPA only renders once Access has already
// authenticated the user, so there is nothing to gate client-side.
export default function App() {
  return (
    <BrowserRouter basename="/board">
      <ConfigProvider theme={RefineThemes.Blue}>
        <AntdApp>
          <Refine
            routerProvider={routerProvider}
            dataProvider={dataProvider}
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
                name: 'preset_conversations',
                list: '/preset-conversations',
                create: '/preset-conversations/create',
                edit: '/preset-conversations/edit/:id',
                meta: { label: '预设会话' },
              },
              {
                name: 'preset_groups',
                list: '/preset-groups',
                create: '/preset-groups/create',
                edit: '/preset-groups/edit/:id',
                meta: { label: '预设群' },
              },
              {
                name: 'preset_letters',
                list: '/preset-letters',
                create: '/preset-letters/create',
                edit: '/preset-letters/edit/:id',
                meta: { label: '预设来信' },
              },
              {
                name: 'tools',
                list: '/tools',
                edit: '/tools/edit/:id',
                meta: { label: '工具管理' },
              },
              {
                name: 'mcp_servers',
                list: '/mcp-servers',
                create: '/mcp-servers/create',
                edit: '/mcp-servers/edit/:id',
                meta: { label: 'MCP 服务器' },
              },
              {
                name: 'model_presets',
                list: '/model-presets',
                create: '/model-presets/create',
                edit: '/model-presets/edit/:id',
                meta: { label: '模型预设' },
              },
              {
                name: 'feature_flags',
                list: '/feature-flags',
                meta: { label: '功能开关' },
              },
              {
                name: 'model_roles',
                list: '/model-roles',
                meta: { label: '系统模型' },
              },
              {
                name: 'billing_packs',
                list: '/billing-packs',
                meta: { label: '计费套餐' },
              },
              {
                name: 'billing_wallet',
                list: '/billing-wallet',
                meta: { label: '钱包 / 发放' },
              },
            ]}
          >
            <ThemedLayout Title={() => <strong>PendingBot Board</strong>}>
              <Routes>
                <Route index element={<NavigateToResource resource="preset_bots" />} />
                <Route path="/preset-bots" element={<PresetBotList />} />
                <Route path="/preset-bots/create" element={<PresetBotCreate />} />
                <Route path="/preset-bots/edit/:id" element={<PresetBotEdit />} />
                <Route path="/preset-conversations" element={<PresetConversationList />} />
                <Route path="/preset-conversations/create" element={<PresetConversationCreate />} />
                <Route path="/preset-conversations/edit/:id" element={<PresetConversationEdit />} />
                <Route path="/preset-groups" element={<PresetGroupList />} />
                <Route path="/preset-groups/create" element={<PresetGroupCreate />} />
                <Route path="/preset-groups/edit/:id" element={<PresetGroupEdit />} />
                <Route path="/preset-letters" element={<PresetLetterList />} />
                <Route path="/preset-letters/create" element={<PresetLetterCreate />} />
                <Route path="/preset-letters/edit/:id" element={<PresetLetterEdit />} />
                <Route path="/tools" element={<ToolList />} />
                <Route path="/tools/edit/:id" element={<ToolEdit />} />
                <Route path="/mcp-servers" element={<McpServerList />} />
                <Route path="/mcp-servers/create" element={<McpServerCreate />} />
                <Route path="/mcp-servers/edit/:id" element={<McpServerEdit />} />
                <Route path="/model-presets" element={<ModelPresetList />} />
                <Route path="/model-presets/create" element={<ModelPresetCreate />} />
                <Route path="/model-presets/edit/:id" element={<ModelPresetEdit />} />
                <Route path="/feature-flags" element={<FeatureFlagsPage />} />
                <Route path="/model-roles" element={<ModelRolesPage />} />
                <Route path="/billing-packs" element={<BillingPacksPage />} />
                <Route path="/billing-wallet" element={<BillingWalletPage />} />
                <Route path="*" element={<NavigateToResource resource="preset_bots" />} />
              </Routes>
            </ThemedLayout>
          </Refine>
        </AntdApp>
      </ConfigProvider>
    </BrowserRouter>
  );
}
