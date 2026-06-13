import { useEffect, useRef } from 'react';
import type { FormInstance } from 'antd';
import {
  List,
  useTable,
  EditButton,
  DeleteButton,
  CreateButton,
  Create,
  Edit,
  useForm,
} from '@refinedev/antd';
import { Table, Space, Form, Input, Switch, Select, InputNumber, Card, Typography } from 'antd';
import { JsonField } from '../components/json-field';

const OUTPUT_MODES = [
  { label: '单条 (single)', value: 'single' },
  { label: '气泡 (bubble)', value: 'bubble' },
];
const VISIBILITIES = [
  { label: '私有 (private)', value: 'private' },
  { label: '公开可邀请 (public_invite)', value: 'public_invite' },
];

// ── 模型池(多模型) ──────────────────────────────────────────
// 真实 bot 的多模型存在 config.modelPool(新键)/ config.arena(旧键别名):
// 新会话从「基础模型 model_id」升级为「从池子里抽主模型」—— 池子 = 价格区间 ∪
// 显式 models,减去 exclude,再按 vendors / 发布窗口约束。signup 克隆预设 bot 时
// 整段 copy config,所以模板设了 modelPool,克隆出的用户 bot 就是多模型。
//
// board 表单把 modelPool 拆成结构化字段(mp_*),其余 config 仍走 JSON 编辑器;
// 提交时合并回 config.modelPool,加载时从 config 拆出来。

type Pool = {
  price_min?: number | null;
  price_max?: number | null;
  models?: string[] | null;
  exclude?: string[] | null;
  vendors?: string[] | null;
  release_window_days?: number | null;
};

// 表单 values → edge 提交体({…基础字段, config})。
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function toPayload(values: Record<string, any>): Record<string, unknown> {
  const {
    config_rest,
    mp_enabled,
    mp_price_min,
    mp_price_max,
    mp_models,
    mp_exclude,
    mp_vendors,
    mp_release_window_days,
    ...base
  } = values;

  // JsonField 把 config_rest 存成已解析的对象;兜底成 {}。
  const restObj: Record<string, unknown> =
    config_rest && typeof config_rest === 'object' && !Array.isArray(config_rest)
      ? { ...(config_rest as Record<string, unknown>) }
      : {};
  // modelPool/arena 永远由结构化字段管,别让它们残留在 rest 里双写。
  delete restObj.modelPool;
  delete restObj.arena;

  const config: Record<string, unknown> = { ...restObj };
  if (mp_enabled) {
    const pool: Pool = {};
    if (mp_price_min != null) pool.price_min = mp_price_min;
    if (mp_price_max != null) pool.price_max = mp_price_max;
    if (mp_models?.length) pool.models = mp_models;
    if (mp_exclude?.length) pool.exclude = mp_exclude;
    if (mp_vendors?.length) pool.vendors = mp_vendors;
    if (mp_release_window_days != null) pool.release_window_days = mp_release_window_days;
    config.modelPool = pool;
  }
  // mp_enabled=false → 不写 modelPool → 克隆出的 bot 只用 model_id(单模型)。

  return { ...base, config };
}

// edit 加载时:从 record.config 拆出 modelPool(兼容旧 arena 键)+ 其余,灌进表单。
function seedFromRecord(form: FormInstance, record: Record<string, unknown> | undefined) {
  if (!record) return;
  const config = (record.config ?? {}) as Record<string, unknown>;
  const pool = (config.modelPool ?? config.arena ?? null) as Pool | null;
  const restObj = { ...config };
  delete restObj.modelPool;
  delete restObj.arena;
  form.setFieldsValue({
    mp_enabled: !!pool,
    mp_price_min: pool?.price_min ?? null,
    mp_price_max: pool?.price_max ?? null,
    mp_models: pool?.models ?? [],
    mp_exclude: pool?.exclude ?? [],
    mp_vendors: pool?.vendors ?? [],
    mp_release_window_days: pool?.release_window_days ?? null,
    config_rest: restObj,
  });
}

export function PresetBotList() {
  const { tableProps } = useTable({ resource: 'preset_bots', syncWithLocation: true });
  return (
    <List headerButtons={<CreateButton />}>
      <Table {...tableProps} rowKey="id">
        <Table.Column dataIndex="slug" title="Slug" />
        <Table.Column dataIndex="display_name" title="名称" />
        <Table.Column dataIndex="model_id" title="基础模型" />
        <Table.Column
          title="多模型"
          render={(_, row: { config?: { modelPool?: unknown; arena?: unknown } }) =>
            row.config?.modelPool || row.config?.arena ? '✓ 池' : '单'
          }
        />
        <Table.Column dataIndex="output_mode" title="输出" />
        <Table.Column dataIndex="visibility" title="可见性" />
        <Table.Column dataIndex="is_active" title="启用" render={(v: boolean) => (v ? '✓' : '—')} />
        <Table.Column
          title="操作"
          render={(_, row: { id: string }) => (
            <Space>
              <EditButton hideText size="small" recordItemId={row.id} />
              <DeleteButton hideText size="small" recordItemId={row.id} />
            </Space>
          )}
        />
      </Table>
    </List>
  );
}

function ModelPoolSection() {
  const form = Form.useFormInstance();
  const enabled = Form.useWatch('mp_enabled', form);
  return (
    <Card size="small" title="模型池(多模型)" style={{ marginBottom: 16 }}>
      <Form.Item
        label="启用模型池"
        name="mp_enabled"
        valuePropName="checked"
        extra="开:新会话从池子抽主模型。关:只用上面的基础模型(单模型)。"
      >
        <Switch />
      </Form.Item>
      {enabled ? (
        <>
          <Space size="large">
            <Form.Item label="价格下限 (price_min)" name="mp_price_min">
              <InputNumber min={0} step={0.01} placeholder="可空" />
            </Form.Item>
            <Form.Item label="价格上限 (price_max)" name="mp_price_max">
              <InputNumber min={0} step={0.01} placeholder="可空" />
            </Form.Item>
            <Form.Item label="发布窗口(天)" name="mp_release_window_days">
              <InputNumber min={0} placeholder="可空" />
            </Form.Item>
          </Space>
          <Form.Item label="显式模型 (models)" name="mp_models" extra="回车添加 model id;与价格区间取并集">
            <Select mode="tags" tokenSeparators={[',']} placeholder="如 anthropic/claude-opus-4.8" />
          </Form.Item>
          <Form.Item label="排除 (exclude)" name="mp_exclude">
            <Select mode="tags" tokenSeparators={[',']} placeholder="从池子里剔除的 model id" />
          </Form.Item>
          <Form.Item label="Vendor 约束 (vendors)" name="mp_vendors">
            <Select mode="tags" tokenSeparators={[',']} placeholder="如 anthropic, google" />
          </Form.Item>
        </>
      ) : (
        <Typography.Text type="secondary">关闭中 —— 克隆出的 bot 只用基础模型。</Typography.Text>
      )}
    </Card>
  );
}

function BotFormBody({ create }: { create?: boolean }) {
  return (
    <>
      <Form.Item label="Slug" name="slug" rules={[{ required: true }]}>
        <Input disabled={!create} />
      </Form.Item>
      <Form.Item label="名称" name="display_name" rules={[{ required: true }]}>
        <Input />
      </Form.Item>
      <Form.Item
        label="基础模型 (model_id)"
        name="model_id"
        rules={[{ required: true }]}
        extra="模型池关闭时用它;开启时作为兜底/起点。"
      >
        <Input placeholder="如 anthropic/claude-opus-4.8" />
      </Form.Item>
      <Form.Item label="输出模式" name="output_mode" rules={[{ required: true }]}>
        <Select options={OUTPUT_MODES} />
      </Form.Item>
      <Form.Item label="可见性" name="visibility" rules={[{ required: true }]}>
        <Select options={VISIBILITIES} />
      </Form.Item>
      <Form.Item label="启用" name="is_active" valuePropName="checked">
        <Switch />
      </Form.Item>
      <ModelPoolSection />
      <JsonField
        name="config_rest"
        label="其余 Config (JSON,不含模型池)"
        kind="object"
        rows={8}
        placeholder='{ "system_prompt": "...", "webSearch": { "enabled": true } }'
      />
    </>
  );
}

export function PresetBotCreate() {
  const { formProps, saveButtonProps, onFinish } = useForm({ resource: 'preset_bots', action: 'create' });
  return (
    <Create saveButtonProps={saveButtonProps}>
      <Form
        {...formProps}
        layout="vertical"
        initialValues={{ output_mode: 'bubble', visibility: 'private', is_active: true, mp_enabled: false }}
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        onFinish={(values) => onFinish(toPayload(values as any))}
      >
        <BotFormBody create />
      </Form>
    </Create>
  );
}

export function PresetBotEdit() {
  const { formProps, saveButtonProps, onFinish, query } = useForm({
    resource: 'preset_bots',
    action: 'edit',
  });
  const seededRef = useRef(false);
  const record = query?.data?.data as Record<string, unknown> | undefined;
  useEffect(() => {
    if (seededRef.current || !record || !formProps.form) return;
    seededRef.current = true;
    seedFromRecord(formProps.form, record);
  }, [record, formProps.form]);
  return (
    <Edit saveButtonProps={saveButtonProps}>
      <Form
        {...formProps}
        layout="vertical"
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        onFinish={(values) => onFinish(toPayload(values as any))}
      >
        <BotFormBody />
      </Form>
    </Edit>
  );
}
