import { useEffect, useRef, useState } from 'react';
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

// system prompt 等放在 config(jsonb)。用一个多行 JSON 文本域编辑整个 config。
//
// 实现要点:文本框绑一个受控的「原始文本」state,用户输入永远原样显示,绝不中途转义。
// - form 的 config 值是「对象」(edge createSchema = z.record(z.string(), z.unknown()))。
// - Edit 模式下 form 初值异步到达,通过 Form.useWatch 监听 config,首次拿到对象时
//   pretty-print 灌进 text state(只同步一次,之后用户编辑以 text state 为准)。
// - Create 模式无初值,默认 '{}'。
// - 每次按键把 text 解析回对象写回 form;非法 JSON 不写回(保留上次合法对象),
//   并由 Form.Item 的 validator 在提交时报错,不静默提交坏值。
function ConfigField() {
  const form = Form.useFormInstance();
  const watched = Form.useWatch('config', form);
  const [text, setText] = useState('{}');
  const seededRef = useRef(false);

  // 首次拿到 form 初值(Edit 模式异步到达)时,把对象 pretty-print 进文本框。
  useEffect(() => {
    if (seededRef.current) return;
    if (watched === undefined) return; // 还没到达,等下一拍
    seededRef.current = true;
    setText(
      watched && typeof watched === 'object' ? JSON.stringify(watched, null, 2) : '{}',
    );
  }, [watched]);

  const onChange = (e: React.ChangeEvent<HTMLTextAreaElement>) => {
    const next = e.target.value;
    setText(next);
    try {
      const parsed = JSON.parse(next);
      // 只在解析成对象时写回 form;非对象/非法保持上次合法值,validator 兜底。
      if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
        form.setFieldValue('config', parsed);
      }
    } catch {
      // 非法 JSON 中间态:不写回,不报错,等提交时由 validator 统一拦。
    }
  };

  return (
    <Form.Item
      label="Config (JSON)"
      name="config"
      // 文本框受控于本地 state,这里不让 Form 反向驱动 textarea 的 value。
      getValueProps={() => ({ value: text })}
      rules={[
        {
          validator: () => {
            try {
              const parsed = JSON.parse(text);
              if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
                return Promise.reject(new Error('Config 必须是 JSON 对象,如 { "system_prompt": "..." }'));
              }
              return Promise.resolve();
            } catch {
              return Promise.reject(new Error('Config 不是合法 JSON'));
            }
          },
        },
      ]}
    >
      <Input.TextArea
        rows={10}
        style={{ fontFamily: 'monospace' }}
        value={text}
        onChange={onChange}
      />
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
