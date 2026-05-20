import { describe, expect, it } from 'vitest';
import { renderAlertBody } from './push';

describe('renderAlertBody', () => {
  it('generic mode always returns the canonical copy', () => {
    expect(renderAlertBody('generic', 'Alice', 'hi there')).toBe('新消息');
    expect(renderAlertBody('generic', null, null)).toBe('新消息');
  });

  it('name mode surfaces the sender, falls back when missing', () => {
    expect(renderAlertBody('name', 'Alice', 'hi there')).toBe('Alice');
    expect(renderAlertBody('name', null, 'hi there')).toBe('新消息');
  });

  it('name_content combines name and trimmed content', () => {
    expect(renderAlertBody('name_content', 'Alice', '  hello\n  world  ')).toBe(
      'Alice：hello world',
    );
  });

  it('name_content truncates long content with an ellipsis', () => {
    const longContent = 'x'.repeat(120);
    const out = renderAlertBody('name_content', 'Alice', longContent);
    expect(out.startsWith('Alice：')).toBe(true);
    expect(out.endsWith('…')).toBe(true);
    expect(out.length).toBeLessThanOrEqual('Alice：'.length + 60 + 1);
  });

  it('name_content drops empty content and just shows the name', () => {
    expect(renderAlertBody('name_content', 'Alice', '   ')).toBe('Alice');
    expect(renderAlertBody('name_content', 'Alice', null)).toBe('Alice');
  });

  it('name_content with no sender falls back to the generic copy as the name', () => {
    expect(renderAlertBody('name_content', null, 'hi')).toBe('新消息：hi');
    expect(renderAlertBody('name_content', null, null)).toBe('新消息');
  });
});
