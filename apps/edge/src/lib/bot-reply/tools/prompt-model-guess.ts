import type { Env } from '../../../types';
import type { ToolCtx } from '../tool-runner';

// Terminal-ish tool: pop a "猜一猜" card into the chat. No model-visible
// result beyond ok/failed. The card drives the reveal via
// POST /v1/conversations/:id/reveal-model on the client.
export async function promptModelGuessTool(
  _env: Env,
  _args: Record<string, unknown>,
  ctx: ToolCtx,
): Promise<string> {
  ctx.emit('tool_call', { name: 'prompt_model_guess' });
  const ok = await ctx.emitGuessPrompt();
  ctx.emit('tool_result', { name: 'prompt_model_guess', ok });
  return JSON.stringify(ok ? { ok: true } : { ok: false, error: 'insert failed' });
}
