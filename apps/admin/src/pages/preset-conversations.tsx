import { List, useTable, EditButton, DeleteButton, CreateButton, Create, Edit, useForm } from '@refinedev/antd';
import { Table, Space, Form, Input, Switch, InputNumber } from 'antd';
import { JsonField } from '../components/json-field';

// 预设会话模板(preset_conversation_templates,slug 主键)。signup 时按模板物化
// 成新用户与某个预设 bot 的会话。messages 是 JSON 数组(元素可为字符串或对象)。

export function PresetConversationList() {
  const { tableProps } = useTable({ resource: 'preset_conversations', syncWithLocation: true });
  return (
    <List headerButtons={<CreateButton />}>
      <Table {...tableProps} rowKey="slug">
        <Table.Column dataIndex="slug" title="Slug" />
        <Table.Column dataIndex="title" title="标题" />
        <Table.Column dataIndex="bot_slug" title="Bot" />
        <Table.Column dataIndex="sort_order" title="排序" />
        <Table.Column dataIndex="enabled" title="启用" render={(v: boolean) => (v ? '✓' : '—')} />
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

function ConvFields({ create }: { create?: boolean }) {
  return (
    <>
      <Form.Item label="Slug" name="slug" rules={[{ required: true }]}>
        <Input disabled={!create} />
      </Form.Item>
      <Form.Item label="标题" name="title" rules={[{ required: true }]}>
        <Input />
      </Form.Item>
      <Form.Item label="Bot Slug" name="bot_slug" rules={[{ required: true }]}>
        <Input placeholder="预设 bot 的 slug(如 self)" />
      </Form.Item>
      <Form.Item label="排序" name="sort_order">
        <InputNumber min={0} />
      </Form.Item>
      <Form.Item label="启用" name="enabled" valuePropName="checked">
        <Switch />
      </Form.Item>
      <JsonField
        name="messages"
        label="消息 (JSON 数组)"
        kind="array"
        rows={12}
        placeholder={'["你好,这是一条预设消息", { "role": "bot", "text": "..." }]'}
      />
    </>
  );
}

export function PresetConversationCreate() {
  const { formProps, saveButtonProps } = useForm({ resource: 'preset_conversations', action: 'create' });
  return (
    <Create saveButtonProps={saveButtonProps}>
      <Form {...formProps} layout="vertical">
        <ConvFields create />
      </Form>
    </Create>
  );
}

export function PresetConversationEdit() {
  const { formProps, saveButtonProps } = useForm({ resource: 'preset_conversations', action: 'edit' });
  return (
    <Edit saveButtonProps={saveButtonProps}>
      <Form {...formProps} layout="vertical">
        <ConvFields />
      </Form>
    </Edit>
  );
}
