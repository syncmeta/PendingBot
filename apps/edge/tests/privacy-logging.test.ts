import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';

const repoRoot = join(import.meta.dirname, '..', '..', '..');

describe('privacy-sensitive logging', () => {
  it('does not log full realtime session events that may contain instructions', () => {
    const source = readFileSync(
      join(repoRoot, 'apps/edge/src/durable-objects/realtime-meter.ts'),
      'utf8',
    );

    expect(source).not.toMatch(/JSON\.stringify\(msg\)/);
    expect(source).not.toMatch(/session\.created[\s\S]{0,200}JSON\.stringify/);
    expect(source).not.toMatch(/session\.updated[\s\S]{0,200}JSON\.stringify/);
  });

  it('does not log raw group-router model output on JSON parse failures', () => {
    const source = readFileSync(
      join(repoRoot, 'apps/edge/src/llm/group-router.ts'),
      'utf8',
    );

    expect(source).not.toMatch(/non-JSON response from small model['"],\s*raw/);
  });

  it('does not log the full OpenAI realtime client-secret response', () => {
    const source = readFileSync(
      join(repoRoot, 'apps/edge/src/routes/realtime.ts'),
      'utf8',
    );

    expect(source).not.toMatch(/openai response missing client_secret['"],\s*data/);
  });
});
