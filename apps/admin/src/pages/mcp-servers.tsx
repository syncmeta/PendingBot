import { List, useTable, EditButton, DeleteButton, CreateButton, Create, Edit, useForm } from '@refinedev/antd';
import { Table, Space, Form, Input, Switch, Select, Tag, Typography } from 'antd';

// MCP server 注册(pendingbot.mcp_servers)。纯配置,全 CRUD。改完 ≤60s 经
// cfg:mcp-servers 生效。**secret_ref 填的是 env var 名字,不是密钥本身**——
// 密钥用 `wrangler secret put <secret_ref>` 单独配。

const TRANSPORTS = [
  { label: 'http', value: 'http' },
  { label: 'sse(未实现)', value: 'sse' },
];
const AUTH_KINDS = [
  { label: '无 (none)', value: 'none' },
  { label: 'Header', value: 'header' },
];

export function McpServerList() {
  const { tableProps } = useTable({ resource: 'mcp_servers', syncWithLocation: true });
  return (
    <List headerButtons={<CreateButton />}>
      <Table {...tableProps} rowKey="id">
        <Table.Column dataIndex="name" title="名称" />
        <Table.Column dataIndex="url" title="URL" />
        <Table.Column dataIndex="transport" title="传输" />
        <Table.Column dataIndex="auth_kind" title="鉴权" />
        <Table.Column
          dataIndex="enabled"
          title="启用"
          render={(v: boolean) => (v ? <Tag color="green">on</Tag> : <Tag>off</Tag>)}
        />
        <Table.Column
          dataIndex="last_health_error"
          title="健康"
          render={(v: string | null) =>
            v ? <Tag color="red">{v}</Tag> : <Tag color="green">ok</Tag>
          }
        />
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

function McpFields({ row }: { row?: { last_health_error?: string | null } }) {
  return (
    <>
      <Form.Item label="名称" name="name" rules={[{ required: true }]}>
        <Input placeholder="模型实际看到的 server 名" />
      </Form.Item>
      <Form.Item label="URL" name="url" rules={[{ required: true, type: 'url' }]}>
        <Input placeholder="https://..." />
      </Form.Item>
      <Form.Item label="传输" name="transport" rules={[{ required: true }]}>
        <Select options={TRANSPORTS} />
      </Form.Item>
      <Form.Item label="鉴权方式" name="auth_kind" rules={[{ required: true }]}>
        <Select options={AUTH_KINDS} />
      </Form.Item>
      <Form.Item label="Auth Header 名" name="auth_header_name" extra="auth_kind=header 时填,如 Authorization">
        <Input placeholder="Authorization" />
      </Form.Item>
      <Form.Item
        label="Secret Ref"
        name="secret_ref"
        extra="env var 的名字(不是密钥本身);密钥用 wrangler secret put <名字> 单独配"
      >
        <Input placeholder="如 MCP_FOO_TOKEN" />
      </Form.Item>
      <Form.Item label="启用" name="enabled" valuePropName="checked">
        <Switch />
      </Form.Item>
      <Form.Item label="备注" name="notes">
        <Input.TextArea rows={2} />
      </Form.Item>
      {row?.last_health_error ? (
        <Typography.Text type="danger">最近健康检查错误:{row.last_health_error}</Typography.Text>
      ) : null}
    </>
  );
}

export function McpServerCreate() {
  const { formProps, saveButtonProps } = useForm({ resource: 'mcp_servers', action: 'create' });
  return (
    <Create saveButtonProps={saveButtonProps}>
      <Form {...formProps} layout="vertical" initialValues={{ transport: 'http', auth_kind: 'none', enabled: true }}>
        <McpFields />
      </Form>
    </Create>
  );
}

export function McpServerEdit() {
  const { formProps, saveButtonProps, query } = useForm({ resource: 'mcp_servers', action: 'edit' });
  const row = query?.data?.data as { last_health_error?: string | null } | undefined;
  return (
    <Edit saveButtonProps={saveButtonProps}>
      <Form {...formProps} layout="vertical">
        <McpFields row={row} />
      </Form>
    </Edit>
  );
}
