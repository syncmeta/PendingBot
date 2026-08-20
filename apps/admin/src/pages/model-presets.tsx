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
import { Table, Space, Form, Input, Switch, InputNumber, Select } from 'antd';
import { JsonField } from '../components/json-field';

// 模型预设(model_presets,slug 主键)。新建机器人第一屏的预设多选来源。
// board 管"规则"(resolver_kind + params),内容由 OpenRouter 目录动态解析
// (edge lib/model-presets.ts)。params 是 jsonb,各 resolver_kind 含义见 placeholder。

const RESOLVER_KINDS = [
  { value: 'top_flagship', label: 'top_flagship — 指定厂商各取旗舰' },
  { value: 'chinese_flagship', label: 'chinese_flagship — 中国厂各取旗舰' },
  { value: 'latest_per_vendor', label: 'latest_per_vendor — 各厂最新' },
  { value: 'fastest', label: 'fastest — 吞吐最高(带质量下限)' },
  { value: 'most_popular', label: 'most_popular — LMArena 评分榜' },
  { value: 'manual', label: 'manual — 手钉清单(应急)' },
];

export function ModelPresetList() {
  const { tableProps } = useTable({ resource: 'model_presets', syncWithLocation: true });
  return (
    <List headerButtons={<CreateButton />}>
      <Table {...tableProps} rowKey="slug">
        <Table.Column dataIndex="slug" title="Slug" />
        <Table.Column dataIndex="title" title="标题" />
        <Table.Column dataIndex="resolver_kind" title="规则" />
        <Table.Column
          dataIndex="default_selected"
          title="默认选中"
          render={(v: boolean) => (v ? '✓' : '—')}
        />
        <Table.Column dataIndex="enabled" title="启用" render={(v: boolean) => (v ? '✓' : '—')} />
        <Table.Column dataIndex="sort_order" title="排序" />
        <Table.Column
          title="操作"
          render={(_, row: { slug: string }) => (
            <Space>
              <EditButton hideText size="small" recordItemId={row.slug} />
              <DeleteButton hideText size="small" recordItemId={row.slug} />
            </Space>
          )}
        />
      </Table>
    </List>
  );
}

function PresetFields({ create }: { create?: boolean }) {
  return (
    <>
      <Form.Item label="Slug" name="slug" rules={[{ required: true }]}>
        <Input disabled={!create} placeholder="top-flagship" />
      </Form.Item>
      <Form.Item label="标题" name="title" rules={[{ required: true }]}>
        <Input placeholder="头两家旗舰" />
      </Form.Item>
      <Form.Item label="描述" name="description">
        <Input placeholder="OpenAI 与 Anthropic 的旗舰模型" />
      </Form.Item>
      <Form.Item label="规则" name="resolver_kind" rules={[{ required: true }]}>
        <Select options={RESOLVER_KINDS} />
      </Form.Item>
      <Form.Item label="默认选中" name="default_selected" valuePropName="checked">
        <Switch />
      </Form.Item>
      <Form.Item label="启用" name="enabled" valuePropName="checked">
        <Switch />
      </Form.Item>
      <Form.Item label="排序" name="sort_order">
        <InputNumber min={0} />
      </Form.Item>
      <JsonField
        name="params"
        label="参数 (JSON)"
        kind="object"
        rows={8}
        placeholder={
          '{ "authors": ["openai","anthropic"], "flagship": "most_expensive" }\n' +
          '// latest/fastest/most_popular: { "count": 5 }; fastest 另含 "min_rating": 1200;\n' +
          '// manual: { "manual_models": ["openai/gpt-5.1", ...] };\n' +
          '// latest_in_series 旗舰: { "flagship": "latest_in_series", "series": "gpt-5" }'
        }
      />
    </>
  );
}

export function ModelPresetCreate() {
  const { formProps, saveButtonProps } = useForm({ resource: 'model_presets', action: 'create' });
  return (
    <Create saveButtonProps={saveButtonProps}>
      <Form {...formProps} layout="vertical">
        <PresetFields create />
      </Form>
    </Create>
  );
}

export function ModelPresetEdit() {
  const { formProps, saveButtonProps } = useForm({ resource: 'model_presets', action: 'edit' });
  return (
    <Edit saveButtonProps={saveButtonProps}>
      <Form {...formProps} layout="vertical">
        <PresetFields />
      </Form>
    </Edit>
  );
}
