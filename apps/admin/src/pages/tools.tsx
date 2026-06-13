import { List, useTable, EditButton, Edit, useForm } from '@refinedev/antd';
import { Table, Space, Form, Input, Switch, Select, Tag, Typography } from 'antd';

// tool 管理(pendingbot.tools)。**只读+改,不建不删** —— 每行映射一个代码
// handler(key→实现),所以没有 Create/Delete。可改:enabled(kill-switch,
// ≤60s 经 cfg:tools-registry 生效)、scopes、模型/人读描述、notes、mcp 绑定。
// key/kind 是身份,只读展示。

const SCOPES = [
  { label: 'chat(bot-reply)', value: 'chat' },
  { label: 'envelope(来信)', value: 'envelope' },
];

export function ToolList() {
  const { tableProps } = useTable({ resource: 'tools', syncWithLocation: true });
  return (
    <List canCreate={false}>
      <Table {...tableProps} rowKey="id">
        <Table.Column dataIndex="key" title="Key" />
        <Table.Column dataIndex="kind" title="类型" />
        <Table.Column
          dataIndex="enabled"
          title="启用"
          render={(v: boolean) => (v ? <Tag color="green">on</Tag> : <Tag>off</Tag>)}
        />
        <Table.Column
          dataIndex="scopes"
          title="Scopes"
          render={(v: string[]) => (Array.isArray(v) ? v.join(', ') : '')}
        />
        <Table.Column
          dataIndex="model_description"
          title="模型描述"
          render={(v: string | null) => (
            <Typography.Text ellipsis style={{ maxWidth: 360 }}>
              {v ?? <Typography.Text type="secondary">(用上游/默认)</Typography.Text>}
            </Typography.Text>
          )}
        />
        <Table.Column
          title="操作"
          render={(_, row: { id: string }) => (
            <Space>
              <EditButton hideText size="small" recordItemId={row.id} />
            </Space>
          )}
        />
      </Table>
    </List>
  );
}

export function ToolEdit() {
  const { formProps, saveButtonProps, query } = useForm({ resource: 'tools', action: 'edit' });
  const row = query?.data?.data as { key?: string; kind?: string } | undefined;
  return (
    <Edit saveButtonProps={saveButtonProps} canDelete={false}>
      <Form {...formProps} layout="vertical">
        {/* key / kind 是身份,只读展示,不入表单 */}
        <Form.Item label="Key">
          <Input value={row?.key} disabled />
        </Form.Item>
        <Form.Item label="类型">
          <Input value={row?.kind} disabled />
        </Form.Item>
        <Form.Item label="启用" name="enabled" valuePropName="checked">
          <Switch />
        </Form.Item>
        <Form.Item label="Scopes" name="scopes" extra="工具暴露在哪些表面">
          <Select mode="multiple" options={SCOPES} />
        </Form.Item>
        <Form.Item
          label="模型描述 (model_description)"
          name="model_description"
          extra="模型实际看到的描述。原生工具:留空会没有描述;MCP 工具:留空用上游自带描述。"
        >
          <Input.TextArea rows={4} />
        </Form.Item>
        <Form.Item label="人读描述 (description)" name="description">
          <Input.TextArea rows={2} />
        </Form.Item>
        <Form.Item label="备注 (notes)" name="notes">
          <Input.TextArea rows={2} />
        </Form.Item>
        <Form.Item label="MCP Server ID" name="mcp_server_id" extra="仅 MCP 工具填,绑定到 mcp_servers 行">
          <Input placeholder="uuid 或留空" />
        </Form.Item>
      </Form>
    </Edit>
  );
}
