import { List, useTable, EditButton, DeleteButton, CreateButton, Create, Edit, useForm } from '@refinedev/antd';
import { Table, Space, Form, Input, Switch, InputNumber, Select } from 'antd';
import { JsonField } from '../components/json-field';

// 预设群模板(preset_group_templates,slug 主键)。bot_slugs 是字符串数组(用 tags
// 输入),messages 是 JSON 数组。

export function PresetGroupList() {
  const { tableProps } = useTable({ resource: 'preset_groups', syncWithLocation: true });
  return (
    <List headerButtons={<CreateButton />}>
      <Table {...tableProps} rowKey="slug">
        <Table.Column dataIndex="slug" title="Slug" />
        <Table.Column dataIndex="title" title="标题" />
        <Table.Column
          dataIndex="bot_slugs"
          title="Bots"
          render={(v: string[]) => (Array.isArray(v) ? v.join(', ') : '')}
        />
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

function GroupFields({ create }: { create?: boolean }) {
  return (
    <>
      <Form.Item label="Slug" name="slug" rules={[{ required: true }]}>
        <Input disabled={!create} />
      </Form.Item>
      <Form.Item label="标题" name="title" rules={[{ required: true }]}>
        <Input />
      </Form.Item>
      <Form.Item label="Bot Slugs" name="bot_slugs">
        <Select mode="tags" placeholder="输入预设 bot 的 slug,回车添加" tokenSeparators={[',']} />
      </Form.Item>
      <Form.Item label="排序" name="sort_order">
        <InputNumber min={0} />
      </Form.Item>
      <Form.Item label="启用" name="enabled" valuePropName="checked">
        <Switch />
      </Form.Item>
      <JsonField name="messages" label="消息 (JSON 数组)" kind="array" rows={12} />
    </>
  );
}

export function PresetGroupCreate() {
  const { formProps, saveButtonProps } = useForm({ resource: 'preset_groups', action: 'create' });
  return (
    <Create saveButtonProps={saveButtonProps}>
      <Form {...formProps} layout="vertical">
        <GroupFields create />
      </Form>
    </Create>
  );
}

export function PresetGroupEdit() {
  const { formProps, saveButtonProps } = useForm({ resource: 'preset_groups', action: 'edit' });
  return (
    <Edit saveButtonProps={saveButtonProps}>
      <Form {...formProps} layout="vertical">
        <GroupFields />
      </Form>
    </Edit>
  );
}
