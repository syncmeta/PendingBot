import { useState } from 'react';
import {
  Card,
  Input,
  InputNumber,
  Typography,
  Space,
  Button,
  Table,
  Descriptions,
  Tag,
  App as AntdApp,
} from 'antd';
import { edgeFetch, EdgeApiError } from '../providers/http';

// 钱包查询 + grant/claw-back。按 user id / email 查余额 + 阈值态 + 最近账本(只读),
// 并直接发放/收回额度(正=发放 负=收回)。后端走 recordCreditIn/recordRefund
// (kind=admin,source=admin)写 pnc_ledger + 同步 WalletDO —— 与充值 webhook 同活路径。
function errMsg(e: unknown): string {
  return e instanceof EdgeApiError ? e.message : String(e);
}

type LedgerRow = {
  id: string;
  kind: string;
  source: string;
  external_ref: string;
  delta_pnc_micros: number;
  created_at: string;
};
type WalletResp = {
  data: {
    user_id: string;
    email: string | null;
    balance_pnc_micros: number;
    threshold_state: string;
    recent_ledger: LedgerRow[];
  };
};

const STATE_COLOR: Record<string, string> = {
  sufficient: 'green',
  low: 'gold',
  throttle: 'orange',
  exhausted: 'red',
};

function fmtPnc(micros: number): string {
  return (micros / 1_000_000).toLocaleString(undefined, {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
}

export function BillingWalletPage() {
  const { message, modal } = AntdApp.useApp();
  const [q, setQ] = useState('');
  const [wallet, setWallet] = useState<WalletResp['data'] | null>(null);
  const [loading, setLoading] = useState(false);
  const [grantPnc, setGrantPnc] = useState<number>(0);
  const [reason, setReason] = useState('');
  const [granting, setGranting] = useState(false);

  const lookup = async () => {
    if (!q.trim()) return;
    setLoading(true);
    try {
      const r = await edgeFetch<WalletResp>({
        method: 'GET',
        path: 'board/billing/wallet',
        query: { q: q.trim() },
      });
      setWallet(r.data);
    } catch (e) {
      setWallet(null);
      message.error(errMsg(e));
    } finally {
      setLoading(false);
    }
  };

  const grant = async () => {
    if (!wallet || grantPnc === 0 || !reason.trim()) return;
    const verb = grantPnc > 0 ? '发放' : '收回';
    modal.confirm({
      title: `确认${verb} ${Math.abs(grantPnc)} PNC?`,
      content: `用户 ${wallet.email ?? wallet.user_id} · 原因：${reason.trim()}`,
      onOk: async () => {
        setGranting(true);
        try {
          await edgeFetch<{ data: unknown }>({
            method: 'POST',
            path: 'board/billing/grant',
            body: { q: wallet.user_id, pnc: grantPnc, reason: reason.trim() },
          });
          message.success(`已${verb}`);
          setGrantPnc(0);
          setReason('');
          await lookup();
        } catch (e) {
          message.error(errMsg(e));
        } finally {
          setGranting(false);
        }
      },
    });
  };

  return (
    <Space direction="vertical" size="large" style={{ width: '100%' }}>
      <Card title="钱包查询" size="small">
        <Space.Compact style={{ width: '100%', maxWidth: 560 }}>
          <Input
            placeholder="user id (UUID) 或 email"
            value={q}
            onChange={(e) => setQ(e.target.value)}
            onPressEnter={lookup}
          />
          <Button type="primary" loading={loading} onClick={lookup}>
            查询
          </Button>
        </Space.Compact>
      </Card>

      {wallet && (
        <>
          <Card size="small">
            <Descriptions column={2} size="small">
              <Descriptions.Item label="User ID">
                <code>{wallet.user_id}</code>
              </Descriptions.Item>
              <Descriptions.Item label="Email">{wallet.email ?? '—'}</Descriptions.Item>
              <Descriptions.Item label="余额">
                <strong>{fmtPnc(wallet.balance_pnc_micros)} PNC</strong>
              </Descriptions.Item>
              <Descriptions.Item label="阈值态">
                <Tag color={STATE_COLOR[wallet.threshold_state] ?? 'default'}>
                  {wallet.threshold_state}
                </Tag>
              </Descriptions.Item>
            </Descriptions>
          </Card>

          <Card title="发放 / 收回额度" size="small">
            <Typography.Paragraph type="secondary" style={{ fontSize: 12 }}>
              正数=发放(补偿 / beta / bug bounty)，负数=收回。收回按可用余额夹住，不扣成负。
            </Typography.Paragraph>
            <Space direction="vertical" style={{ width: '100%', maxWidth: 560 }}>
              <InputNumber
                style={{ width: '100%' }}
                placeholder="PNC(正=发放 负=收回)"
                value={grantPnc}
                onChange={(v) => setGrantPnc(Number(v))}
              />
              <Input
                placeholder="原因(必填，入审计)"
                value={reason}
                onChange={(e) => setReason(e.target.value)}
              />
              <Button
                type="primary"
                danger={grantPnc < 0}
                loading={granting}
                disabled={grantPnc === 0 || !reason.trim()}
                onClick={grant}
              >
                {grantPnc < 0 ? '收回' : '发放'}
              </Button>
            </Space>
          </Card>

          <Card title="最近账本(30 条)" size="small">
            <Table<LedgerRow>
              dataSource={wallet.recent_ledger}
              rowKey="id"
              pagination={false}
              size="small"
              columns={[
                { title: '类型', dataIndex: 'kind', width: 100 },
                { title: '来源', dataIndex: 'source', width: 140 },
                {
                  title: '变动',
                  dataIndex: 'delta_pnc_micros',
                  width: 120,
                  render: (v: number) => (
                    <span style={{ color: v > 0 ? '#2E7D5B' : '#B14B3C' }}>
                      {v > 0 ? '+' : ''}
                      {fmtPnc(v)}
                    </span>
                  ),
                },
                {
                  title: 'external_ref',
                  dataIndex: 'external_ref',
                  render: (v: string) => <code style={{ fontSize: 11 }}>{v}</code>,
                },
                {
                  title: '时间',
                  dataIndex: 'created_at',
                  width: 180,
                  render: (v: string) => new Date(v).toLocaleString(),
                },
              ]}
            />
          </Card>
        </>
      )}
    </Space>
  );
}
