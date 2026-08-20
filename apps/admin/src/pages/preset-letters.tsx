import { List, useTable, EditButton, DeleteButton, CreateButton, Create, Edit, useForm } from '@refinedev/antd';
import { Table, Space, Form, Input, InputNumber, Typography } from 'antd';

// 预设来信(preset_letters,slug 主键)。signup 的 seed_example_letter() 从此表读
// slug='readme' 那封,物化进新用户 self 会话。body_md 是 markdown 长文。

export function PresetLetterList() {
  const { tableProps } = useTable({ resource: 'preset_letters', syncWithLocation: true });
  return (
    <List headerButtons={<CreateButton />}>
      <Table {...tableProps} rowKey="slug">
        <Table.Column dataIndex="slug" title="Slug" />
        <Table.Column dataIndex="title" title="标题" />
        <Table.Column
          dataIndex="summary"
          title="摘要"
          render={(v: string) => (
            <Typography.Text ellipsis style={{ maxWidth: 320 }}>
              {v}
            </Typography.Text>
          )}
        />
        <Table.Column dataIndex="version" title="版本" />
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

function LetterFields({ create }: { create?: boolean }) {
  return (
    <>
      <Form.Item
        label="Slug"
        name="slug"
        rules={[{ required: true }]}
        extra={create ? 'signup 物化的那封固定用 slug = readme' : undefined}
      >
        <Input disabled={!create} />
      </Form.Item>
      <Form.Item label="标题" name="title" rules={[{ required: true }]}>
        <Input />
      </Form.Item>
      <Form.Item label="摘要" name="summary" rules={[{ required: true }]}>
        <Input.TextArea rows={2} />
      </Form.Item>
      <Form.Item label="正文 (Markdown)" name="body_md" rules={[{ required: true }]}>
        <Input.TextArea rows={16} style={{ fontFamily: 'monospace' }} />
      </Form.Item>
      <Form.Item label="版本" name="version">
        <InputNumber min={1} />
      </Form.Item>
    </>
  );
}

export function PresetLetterCreate() {
  const { formProps, saveButtonProps } = useForm({ resource: 'preset_letters', action: 'create' });
  return (
    <Create saveButtonProps={saveButtonProps}>
      <Form {...formProps} layout="vertical">
        <LetterFields create />
      </Form>
    </Create>
  );
}

export function PresetLetterEdit() {
  const { formProps, saveButtonProps } = useForm({ resource: 'preset_letters', action: 'edit' });
  return (
    <Edit saveButtonProps={saveButtonProps}>
      <Form {...formProps} layout="vertical">
        <LetterFields />
      </Form>
    </Edit>
  );
}
