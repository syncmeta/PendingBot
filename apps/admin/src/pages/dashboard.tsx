import { useList } from '@refinedev/core';
import { Link } from 'react-router';
import { Card, Col, Row, Typography, Statistic, Space, Tag, theme } from 'antd';
import {
  RobotOutlined,
  MessageOutlined,
  TeamOutlined,
  MailOutlined,
  ToolOutlined,
  ApiOutlined,
  ControlOutlined,
  SafetyCertificateOutlined,
  ArrowRightOutlined,
} from '@ant-design/icons';
import type { ReactNode } from 'react';

type Section = {
  resource?: string; // table-backed → show live count
  to: string;
  label: string;
  desc: string;
  icon: ReactNode;
  color: string;
};

const CONTENT: Section[] = [
  { resource: 'preset_bots', to: '/preset-bots', label: '预设机器人', desc: '新用户默认机器人模板(含多模型池)', icon: <RobotOutlined />, color: '#16a34a' },
  { resource: 'preset_conversations', to: '/preset-conversations', label: '预设会话', desc: 'signup 物化的示例会话', icon: <MessageOutlined />, color: '#0ea5e9' },
  { resource: 'preset_groups', to: '/preset-groups', label: '预设群', desc: '默认群模板', icon: <TeamOutlined />, color: '#8b5cf6' },
  { resource: 'preset_letters', to: '/preset-letters', label: '预设来信', desc: '新用户欢迎信(slug=readme)', icon: <MailOutlined />, color: '#f59e0b' },
];

const CONFIG: Section[] = [
  { resource: 'tools', to: '/tools', label: '工具管理', desc: '开关 / scopes / 模型描述(不建不删)', icon: <ToolOutlined />, color: '#0d9488' },
  { resource: 'mcp_servers', to: '/mcp-servers', label: 'MCP 服务器', desc: 'MCP server 注册 + 鉴权绑定', icon: <ApiOutlined />, color: '#db2777' },
  { to: '/feature-flags', label: '功能开关', desc: 'billing / posthog / langfuse 运行时切', icon: <ControlOutlined />, color: '#64748b' },
];

function SectionCard({ s }: { s: Section }) {
  // Only fetch a count for table-backed resources; 1 row is enough for `total`.
  const { result, query } = useList({
    resource: s.resource ?? 'preset_bots',
    pagination: { currentPage: 1, pageSize: 1 },
    queryOptions: { enabled: !!s.resource },
  });
  const isLoading = query.isLoading;
  const total = result?.total;
  const { token } = theme.useToken();
  return (
    <Col xs={24} sm={12} xl={8}>
      <Link to={s.to}>
        <Card
          hoverable
          style={{ borderRadius: 12, height: '100%' }}
          styles={{ body: { padding: 20 } }}
        >
          <Space align="start" style={{ justifyContent: 'space-between', width: '100%' }}>
            <span
              style={{
                display: 'inline-flex',
                alignItems: 'center',
                justifyContent: 'center',
                width: 44,
                height: 44,
                borderRadius: 12,
                background: `${s.color}1a`,
                color: s.color,
                fontSize: 22,
              }}
            >
              {s.icon}
            </span>
            {s.resource ? (
              <Statistic value={isLoading ? undefined : (total ?? 0)} valueStyle={{ fontSize: 24 }} />
            ) : (
              <Tag color="default">4 开关</Tag>
            )}
          </Space>
          <div style={{ marginTop: 14 }}>
            <Typography.Title level={5} style={{ marginBottom: 2 }}>
              {s.label}
            </Typography.Title>
            <Typography.Text type="secondary" style={{ fontSize: 13 }}>
              {s.desc}
            </Typography.Text>
          </div>
          <div style={{ marginTop: 10, color: token.colorPrimary, fontSize: 13 }}>
            管理 <ArrowRightOutlined />
          </div>
        </Card>
      </Link>
    </Col>
  );
}

export function Dashboard() {
  const { token } = theme.useToken();
  return (
    <div style={{ maxWidth: 1080, margin: '0 auto' }}>
      <div style={{ marginBottom: 8 }}>
        <Typography.Title level={3} style={{ marginBottom: 4 }}>
          PendingBot Board
        </Typography.Title>
        <Space size={8} wrap>
          <Typography.Text type="secondary">内容 / 预设 / 配置管理台</Typography.Text>
          <Tag icon={<SafetyCertificateOutlined />} color="green" style={{ marginInlineStart: 4 }}>
            Cloudflare Access 守护
          </Tag>
        </Space>
      </div>

      <Typography.Title level={5} style={{ color: token.colorTextSecondary, marginTop: 28 }}>
        内容预设
      </Typography.Title>
      <Row gutter={[16, 16]}>
        {CONTENT.map((s) => (
          <SectionCard key={s.to} s={s} />
        ))}
      </Row>

      <Typography.Title level={5} style={{ color: token.colorTextSecondary, marginTop: 28 }}>
        配置
      </Typography.Title>
      <Row gutter={[16, 16]}>
        {CONFIG.map((s) => (
          <SectionCard key={s.to} s={s} />
        ))}
      </Row>
    </div>
  );
}
