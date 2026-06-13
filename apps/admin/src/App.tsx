import { Refine } from '@refinedev/core';
import { ThemedLayout, RefineThemes, useNotificationProvider } from '@refinedev/antd';
import routerProvider, { NavigateToResource } from '@refinedev/react-router';
import { BrowserRouter, Routes, Route } from 'react-router';
import { ConfigProvider, App as AntdApp, theme as antdTheme } from 'antd';
import {
  RobotOutlined,
  MessageOutlined,
  TeamOutlined,
  MailOutlined,
  ToolOutlined,
  ApiOutlined,
  ControlOutlined,
  AppstoreOutlined,
  SettingOutlined,
} from '@ant-design/icons';
import '@refinedev/antd/dist/reset.css';

import { dataProvider } from './providers/data-provider';
import { Dashboard } from './pages/dashboard';
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
import { FeatureFlagsPage } from './pages/feature-flags';
import { BoardTitle } from './components/board-title';

// No authProvider / login route: served same-origin under /board behind
// Cloudflare Access (the sole identity gate). The SPA only renders once Access
// has authenticated the user.
export default function App() {
  return (
    <BrowserRouter basename="/board">
      <ConfigProvider
        theme={{
          ...RefineThemes.Green,
          algorithm: antdTheme.defaultAlgorithm,
          token: {
            ...RefineThemes.Green.token,
            borderRadius: 8,
            fontSize: 14,
          },
        }}
      >
        <AntdApp>
          <Refine
            routerProvider={routerProvider}
            dataProvider={dataProvider}
            notificationProvider={useNotificationProvider}
            options={{ disableTelemetry: true, warnWhenUnsavedChanges: true }}
            resources={[
              // 分组父项(不可导航,纯菜单分组)。
              { name: 'content', meta: { label: '内容预设', icon: <AppstoreOutlined /> } },
              {
                name: 'preset_bots',
                list: '/preset-bots',
                create: '/preset-bots/create',
                edit: '/preset-bots/edit/:id',
                meta: { parent: 'content', label: '预设机器人', icon: <RobotOutlined /> },
              },
              {
                name: 'preset_conversations',
                list: '/preset-conversations',
                create: '/preset-conversations/create',
                edit: '/preset-conversations/edit/:id',
                meta: { parent: 'content', label: '预设会话', icon: <MessageOutlined /> },
              },
              {
                name: 'preset_groups',
                list: '/preset-groups',
                create: '/preset-groups/create',
                edit: '/preset-groups/edit/:id',
                meta: { parent: 'content', label: '预设群', icon: <TeamOutlined /> },
              },
              {
                name: 'preset_letters',
                list: '/preset-letters',
                create: '/preset-letters/create',
                edit: '/preset-letters/edit/:id',
                meta: { parent: 'content', label: '预设来信', icon: <MailOutlined /> },
              },
              { name: 'config', meta: { label: '配置', icon: <SettingOutlined /> } },
              {
                name: 'tools',
                list: '/tools',
                edit: '/tools/edit/:id',
                meta: { parent: 'config', label: '工具管理', icon: <ToolOutlined /> },
              },
              {
                name: 'mcp_servers',
                list: '/mcp-servers',
                create: '/mcp-servers/create',
                edit: '/mcp-servers/edit/:id',
                meta: { parent: 'config', label: 'MCP 服务器', icon: <ApiOutlined /> },
              },
              {
                name: 'feature_flags',
                list: '/feature-flags',
                meta: { parent: 'config', label: '功能开关', icon: <ControlOutlined /> },
              },
            ]}
          >
            <ThemedLayout
              Title={({ collapsed }) => <BoardTitle collapsed={collapsed} />}
            >
              <Routes>
                <Route index element={<Dashboard />} />
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
                <Route path="/feature-flags" element={<FeatureFlagsPage />} />
                <Route path="*" element={<NavigateToResource resource="preset_bots" />} />
              </Routes>
            </ThemedLayout>
          </Refine>
        </AntdApp>
      </ConfigProvider>
    </BrowserRouter>
  );
}
