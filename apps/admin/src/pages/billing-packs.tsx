import { useEffect, useState } from 'react';
import {
  Card,
  Input,
  InputNumber,
  Typography,
  Space,
  Button,
  Table,
  App as AntdApp,
  Spin,
  Tag,
} from 'antd';
import { edgeFetch, EdgeApiError } from '../providers/http';

// 充值套餐 product_id → PNC 映射。后端 cfg:billing-packs KV(覆盖 ?? 代码默认,
// 逐 product 合成 —— 见 apps/edge/src/lib/billing-packs.ts)。两组销售通道:
//   iap_ios        — ASC 建的 IAP product id
//   polar_checkout — Polar 建的 product id
// 在这里填「真实 product id → PNC / markup」即运行时生效,不用改代码发版。
function errMsg(e: unknown): string {
  return e instanceof EdgeApiError ? e.message : String(e);
}

type Pack = { pnc: number; markupSnapshot: number };
type SourceData = {
  defaults: Record<string, Pack>;
  overrides: Record<string, Pack>;
  effective: Record<string, Pack>;
};
type PacksResp = { data: Record<string, SourceData> };

const SOURCE_LABELS: Record<string, string> = {
  iap_ios: 'iOS 内购(App Store）',
  polar_checkout: 'Polar 网页 / Mac 结算',
};

type Row = {
  productId: string;
  pnc: number;
  markupSnapshot: number;
  overridden: boolean;
  isDefault: boolean;
};

function toRows(sd: SourceData): Row[] {
  return Object.entries(sd.effective).map(([productId, p]) => ({
    productId,
    pnc: p.pnc,
    markupSnapshot: p.markupSnapshot,
    overridden: productId in sd.overrides,
    isDefault: productId in sd.defaults,
  }));
}

export function BillingPacksPage() {
  const { message } = AntdApp.useApp();
  const [data, setData] = useState<PacksResp['data'] | null>(null);
  const [saving, setSaving] = useState(false);
  // 新增行的草稿(每通道一份)。
  const [draft, setDraft] = useState<
    Record<string, { productId: string; pnc: number; markup: number }>
  >({});

  const load = async () => {
    const r = await edgeFetch<PacksResp>({ method: 'GET', path: 'board/billing/packs' });
    setData(r.data);
  };
  useEffect(() => {
    load().catch((e) => message.error(errMsg(e)));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // PUT 一个通道的一个 product 覆盖(pack=null 清除覆盖)。
  const putPack = async (source: string, productId: string, pack: Pack | null) => {
    setSaving(true);
    try {
      await edgeFetch<{ data: unknown }>({
        method: 'PUT',
        path: 'board/billing/packs',
        body: { [source]: { [productId]: pack } },
      });
      await load();
      message.success('已更新，数秒内全球生效');
    } catch (e) {
      message.error(errMsg(e));
    } finally {
      setSaving(false);
    }
  };

  if (!data) return <Spin />;

  return (
    <Space direction="vertical" size="large" style={{ width: '100%' }}>
      <Typography.Paragraph type="secondary" style={{ fontSize: 12 }}>
        充值套餐 <code>product_id → PNC</code> 映射。留空 KV 时用代码默认(占位 id)。ASC / Polar
        建好真实商品后，在对应通道「新增映射」填真实 product id + PNC + markup 即生效。markupSnapshot
        随每笔充值落账(利润快照)，不进运行时消费扣费。
      </Typography.Paragraph>

      {Object.entries(data).map(([source, sd]) => {
        const rows = toRows(sd);
        const d = draft[source] ?? { productId: '', pnc: 270, markup: 2.0 };
        return (
          <Card key={source} title={SOURCE_LABELS[source] ?? source} size="small">
            <Table<Row>
              dataSource={rows}
              rowKey="productId"
              pagination={false}
              size="small"
              columns={[
                {
                  title: 'Product ID',
                  dataIndex: 'productId',
                  render: (v: string, r: Row) => (
                    <Space size={4}>
                      <code>{v}</code>
                      {r.overridden ? (
                        <Tag color="blue">已覆盖</Tag>
                      ) : (
                        <Tag>代码默认</Tag>
                      )}
                    </Space>
                  ),
                },
                { title: 'PNC', dataIndex: 'pnc', width: 100 },
                { title: 'markup', dataIndex: 'markupSnapshot', width: 100 },
                {
                  title: '操作',
                  width: 160,
                  render: (_: unknown, r: Row) =>
                    r.overridden ? (
                      <Button
                        size="small"
                        loading={saving}
                        onClick={() => putPack(source, r.productId, null)}
                      >
                        {r.isDefault ? '恢复代码默认' : '删除'}
                      </Button>
                    ) : (
                      <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                        改此项 → 下方按同名 id 覆盖
                      </Typography.Text>
                    ),
                },
              ]}
            />
            <Space.Compact style={{ marginTop: 12, width: '100%', maxWidth: 640 }}>
              <Input
                placeholder="product_id(如 com.pendingbot.pnc.pack1)"
                value={d.productId}
                onChange={(e) =>
                  setDraft((s) => ({ ...s, [source]: { ...d, productId: e.target.value } }))
                }
              />
              <InputNumber
                placeholder="PNC"
                min={1}
                value={d.pnc}
                onChange={(v) => setDraft((s) => ({ ...s, [source]: { ...d, pnc: Number(v) } }))}
              />
              <InputNumber
                placeholder="markup"
                min={0.01}
                step={0.1}
                value={d.markup}
                onChange={(v) => setDraft((s) => ({ ...s, [source]: { ...d, markup: Number(v) } }))}
              />
              <Button
                type="primary"
                loading={saving}
                disabled={!d.productId.trim() || !(d.pnc > 0) || !(d.markup > 0)}
                onClick={() =>
                  putPack(source, d.productId.trim(), { pnc: d.pnc, markupSnapshot: d.markup })
                }
              >
                新增 / 覆盖
              </Button>
            </Space.Compact>
          </Card>
        );
      })}
    </Space>
  );
}
