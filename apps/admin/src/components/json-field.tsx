import { useEffect, useRef, useState } from 'react';
import { Form, Input } from 'antd';

// Generic JSON field editor (object OR array) for board forms.
//
// Same controlled-text pattern as preset-bots' ConfigField: the textarea's
// text state is the source of truth (user input is never mid-flight escaped);
// the parsed value is written back to the form only when it parses to the
// expected kind; a Form.Item validator gates submit so a bad value can't slip
// through silently.
export function JsonField({
  name,
  label,
  kind,
  rows = 10,
  placeholder,
}: {
  name: string;
  label: string;
  kind: 'object' | 'array';
  rows?: number;
  placeholder?: string;
}) {
  const form = Form.useFormInstance();
  const watched = Form.useWatch(name, form);
  const empty = kind === 'array' ? '[]' : '{}';
  const [text, setText] = useState(empty);
  const seededRef = useRef(false);

  // Seed the textarea once when the form's initial value arrives (Edit mode is
  // async); afterwards the text state owns the content.
  useEffect(() => {
    if (seededRef.current) return;
    if (watched === undefined) return;
    seededRef.current = true;
    setText(watched && typeof watched === 'object' ? JSON.stringify(watched, null, 2) : empty);
  }, [watched, empty]);

  const isKind = (p: unknown) =>
    kind === 'array' ? Array.isArray(p) : !!p && typeof p === 'object' && !Array.isArray(p);

  const onChange = (e: React.ChangeEvent<HTMLTextAreaElement>) => {
    const next = e.target.value;
    setText(next);
    try {
      const parsed = JSON.parse(next);
      if (isKind(parsed)) form.setFieldValue(name, parsed);
    } catch {
      // mid-edit invalid JSON: keep last valid value, validator catches on submit.
    }
  };

  return (
    <Form.Item
      label={label}
      name={name}
      getValueProps={() => ({ value: text })}
      rules={[
        {
          validator: () => {
            try {
              const parsed = JSON.parse(text);
              return isKind(parsed)
                ? Promise.resolve()
                : Promise.reject(
                    new Error(`${label} 必须是 JSON ${kind === 'array' ? '数组' : '对象'}`),
                  );
            } catch {
              return Promise.reject(new Error(`${label} 不是合法 JSON`));
            }
          },
        },
      ]}
    >
      <Input.TextArea
        rows={rows}
        style={{ fontFamily: 'monospace' }}
        value={text}
        onChange={onChange}
        placeholder={placeholder}
      />
    </Form.Item>
  );
}
