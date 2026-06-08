import { useEffect, useState } from 'react';
import { Card, Switch, Typography, Space, Button, App as AntdApp, Spin, Tooltip } from 'antd';
import { edgeFetch, EdgeApiError } from '../providers/http';

// 把 edge 错误渲染成干净的中文 message(EdgeApiError 已带 http.ts 备好的 message),
// 不要 String(e) —— 那会带上 "EdgeApiError:" 类名前缀。
function errMsg(e: unknown): string {
  return e instanceof EdgeApiError ? e.message : String(e);
}

type FlagRow = { override: boolean | null; envDefault: boolean; effective: boolean; readonly?: boolean };
type FlagsResp = { data: Record<'billing' | 'posthog' | 'langfuse' | 'sentry', FlagRow> };

const LABELS: Record<string, string> = {
  billing: '计费(门禁+扣费)',
  posthog: 'PostHog 产品分析',
  langfuse: 'Langfuse LLM 追踪',
  sentry: 'Sentry 错误追踪',
};

export function FeatureFlagsPage() {
  const { message } = AntdApp.useApp();
  const [flags, setFlags] = useState<FlagsResp['data'] | null>(null);
  const [saving, setSaving] = useState<string | null>(null);

  const load = async () => {
    const r = await edgeFetch<FlagsResp>({ method: 'GET', path: 'board/feature-flags' });
    setFlags(r.data);
  };
  useEffect(() => {
    load().catch((e) => message.error(errMsg(e)));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const put = async (name: string, value: boolean | null) => {
    setSaving(name);
    try {
      await edgeFetch<{ data: unknown }>({
        method: 'PUT',
        path: 'board/feature-flags',
        body: { [name]: value },
      });
      await load();
      message.success('已更新,数秒内全球生效');
    } catch (e) {
      message.error(String(e));
    } finally {
      setSaving(null);
    }
  };

  if (!flags) return <Spin />;

  const order: Array<'billing' | 'posthog' | 'langfuse' | 'sentry'> = [
    'billing',
    'posthog',
    'langfuse',
    'sentry',
  ];
  return (
    <Card title="功能开关">
      <Space direction="vertical" size="large" style={{ width: '100%' }}>
        {order.map((name) => {
          const f = flags[name];
          const ro = !!f.readonly;
          return (
            <Space key={name} align="center" style={{ justifyContent: 'space-between', width: '100%' }}>
              <Space direction="vertical" size={0}>
                <Typography.Text strong>{LABELS[name]}</Typography.Text>
                <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                  env 默认: {f.envDefault ? 'on' : 'off'}
                  {f.override !== null ? ` · 已覆盖为 ${f.effective ? 'on' : 'off'}` : ''}
                  {ro ? ' · 只读(改需重部署)' : ''}
                </Typography.Text>
              </Space>
              <Space>
                {f.override !== null && !ro && (
                  <Button
                    size="small"
                    type="link"
                    loading={saving === name}
                    onClick={() => put(name, null)}
                  >
                    恢复 env 默认
                  </Button>
                )}
                {ro ? (
                  <Tooltip title="改 Sentry 需改 wrangler.jsonc env 并重部署:错误捕获器的开关必须零运行时依赖,不能走 KV/DB。">
                    <Switch checked={f.effective} disabled />
                  </Tooltip>
                ) : (
                  <Switch
                    checked={f.effective}
                    loading={saving === name}
                    onChange={(v) => put(name, v)}
                  />
                )}
              </Space>
            </Space>
          );
        })}
      </Space>
    </Card>
  );
}
