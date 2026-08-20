import { useEffect, useState } from 'react';
import { Card, Input, Typography, Space, Button, App as AntdApp, Spin } from 'antd';
import { edgeFetch, EdgeApiError } from '../providers/http';

// Mirror of feature-flags.tsx, but each row is a model-slug string (board
// override ?? code default) instead of a boolean. Backed by the single KV blob
// at /v1/board/model-roles (GET per-role {override, codeDefault, effective};
// PUT a slug to override, null to clear → fall back to the code default).
function errMsg(e: unknown): string {
  return e instanceof EdgeApiError ? e.message : String(e);
}

type RoleRow = { override: string | null; codeDefault: string; effective: string };
type RolesResp = { data: Record<string, RoleRow> };

// Human labels for the system model-roles (keys = MODEL_ROLE_KEYS in
// apps/edge/src/lib/model-roles.ts). Unknown keys fall back to the raw key.
const LABELS: Record<string, string> = {
  title: '会话标题(小模型起名)',
  groupRouter: '群消息路由(决定唤醒哪些机器人)',
  groupBotIntro: '群机器人自我介绍',
  vision: '识图 / 视觉(看图片)',
  envelopeExplorer: '写信 — 探索阶段',
  envelopeCollaborator: '写信 — 协作阶段',
  voiceDefault: '语音通话默认模型',
};

const ORDER = [
  'title',
  'groupRouter',
  'groupBotIntro',
  'vision',
  'envelopeExplorer',
  'envelopeCollaborator',
  'voiceDefault',
];

export function ModelRolesPage() {
  const { message } = AntdApp.useApp();
  const [roles, setRoles] = useState<RolesResp['data'] | null>(null);
  const [draft, setDraft] = useState<Record<string, string>>({});
  const [saving, setSaving] = useState<string | null>(null);

  const load = async () => {
    const r = await edgeFetch<RolesResp>({ method: 'GET', path: 'board/model-roles' });
    setRoles(r.data);
    const d: Record<string, string> = {};
    for (const k of Object.keys(r.data)) d[k] = r.data[k].effective;
    setDraft(d);
  };
  useEffect(() => {
    load().catch((e) => message.error(errMsg(e)));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const put = async (name: string, value: string | null) => {
    setSaving(name);
    try {
      await edgeFetch<{ data: unknown }>({
        method: 'PUT',
        path: 'board/model-roles',
        body: { [name]: value },
      });
      await load();
      message.success('已更新,数秒内全球生效');
    } catch (e) {
      message.error(errMsg(e));
    } finally {
      setSaving(null);
    }
  };

  if (!roles) return <Spin />;

  return (
    <Card title="系统模型角色">
      <Typography.Paragraph type="secondary" style={{ fontSize: 12, marginBottom: 20 }}>
        平台各功能(标题 / 群路由 / 识图 / 写信 / 语音)兜底用的默认模型 slug。改这里数秒内全球生效;清空再保存(或点「恢复默认」)= 回到代码默认。这些是<strong>系统任务</strong>,不是用户/机器人选的聊天模型(那走「模型预设」)。
      </Typography.Paragraph>
      <Space direction="vertical" size="large" style={{ width: '100%' }}>
        {ORDER.filter((n) => roles[n]).map((name) => {
          const r = roles[name];
          const overridden = r.override !== null;
          const value = draft[name] ?? '';
          const dirty = value !== r.effective;
          return (
            <Space key={name} direction="vertical" size={2} style={{ width: '100%' }}>
              <Typography.Text strong>{LABELS[name] ?? name}</Typography.Text>
              <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                代码默认: <code>{r.codeDefault}</code>
                {overridden ? ` · 已覆盖为 ${r.effective}` : ' · (当前用代码默认)'}
              </Typography.Text>
              <Space.Compact style={{ width: '100%', maxWidth: 560 }}>
                <Input
                  value={value}
                  placeholder={r.codeDefault}
                  onChange={(e) => setDraft((d) => ({ ...d, [name]: e.target.value }))}
                  onPressEnter={() => dirty && value.trim() && put(name, value.trim())}
                />
                <Button
                  type="primary"
                  loading={saving === name}
                  disabled={!dirty || !value.trim()}
                  onClick={() => put(name, value.trim())}
                >
                  保存
                </Button>
                {overridden && (
                  <Button loading={saving === name} onClick={() => put(name, null)}>
                    恢复默认
                  </Button>
                )}
              </Space.Compact>
            </Space>
          );
        })}
      </Space>
    </Card>
  );
}
