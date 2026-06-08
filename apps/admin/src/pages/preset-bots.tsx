import { List, useTable, EditButton, DeleteButton, CreateButton, Create, Edit, useForm } from '@refinedev/antd';
import { Table, Space, Form, Input, Switch, Select } from 'antd';

const OUTPUT_MODES = [
  { label: '单条 (single)', value: 'single' },
  { label: '气泡 (bubble)', value: 'bubble' },
];
const VISIBILITIES = [
  { label: '私有 (private)', value: 'private' },
  { label: '公开可邀请 (public_invite)', value: 'public_invite' },
];

export function PresetBotList() {
  const { tableProps } = useTable({ resource: 'preset_bots', syncWithLocation: true });
  return (
    <List headerButtons={<CreateButton />}>
      <Table {...tableProps} rowKey="id">
        <Table.Column dataIndex="slug" title="Slug" />
        <Table.Column dataIndex="display_name" title="名称" />
        <Table.Column dataIndex="model_id" title="模型" />
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

// system prompt 等放在 config(jsonb)。先用一个多行 JSON 文本域编辑整个 config。
function ConfigField() {
  return (
    <Form.Item
      label="Config (JSON)"
      name="config"
      getValueProps={(v) => ({ value: v ? JSON.stringify(v, null, 2) : '{}' })}
      normalize={(v) => {
        try {
          return JSON.parse(v);
        } catch {
          return v; // 让校验在提交时由 edge 兜;此处不阻断输入
        }
      }}
    >
      <Input.TextArea rows={10} style={{ fontFamily: 'monospace' }} />
    </Form.Item>
  );
}

function BotFields() {
  return (
    <>
      <Form.Item label="Slug" name="slug" rules={[{ required: true }]}>
        <Input />
      </Form.Item>
      <Form.Item label="名称" name="display_name" rules={[{ required: true }]}>
        <Input />
      </Form.Item>
      <Form.Item label="模型 ID" name="model_id" rules={[{ required: true }]}>
        <Input placeholder="如 claude-opus-4.7" />
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
      <ConfigField />
    </>
  );
}

export function PresetBotCreate() {
  const { formProps, saveButtonProps } = useForm({ resource: 'preset_bots', action: 'create' });
  return (
    <Create saveButtonProps={saveButtonProps}>
      <Form {...formProps} layout="vertical">
        <BotFields />
      </Form>
    </Create>
  );
}

export function PresetBotEdit() {
  const { formProps, saveButtonProps } = useForm({ resource: 'preset_bots', action: 'edit' });
  return (
    <Edit saveButtonProps={saveButtonProps}>
      <Form {...formProps} layout="vertical">
        <BotFields />
      </Form>
    </Edit>
  );
}
