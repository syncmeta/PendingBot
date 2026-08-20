import type { Env } from '../../../types';
import { serviceClient } from '../../supabase';
import { readAttachmentForTool } from '../../../llm/vision';
import { UUID_RE } from '../../ids';
import type { ToolCtx } from '../tool-runner';

// read_attachment — let the model read an attachment visible in this
// conv's history: an image, a PDF, or any other uploaded file. The
// system prompt's "## 历史图片附件" / "## 文件附件" sections list every
// attachment with an 8-char ID prefix; the bot passes that prefix (or
// the full UUID) plus a question. We resolve prefix → full UUID against
// this conversation's attachments table (so the model can't poke at
// attachments from other convs even if it guesses an id), then call
// readAttachmentForTool — which parses images/PDFs via a model and
// returns plain files' text content directly.
export async function readAttachmentTool(
  env: Env,
  args: Record<string, unknown>,
  ctx: ToolCtx,
): Promise<string> {
  const idArg = String(args.attachment_id ?? '').trim();
  const question = String(args.question ?? '').trim();
  if (!idArg) return JSON.stringify({ error: 'attachment_id is required' });
  if (!question) return JSON.stringify({ error: 'question is required' });
  if (question.length > 500) {
    return JSON.stringify({ error: 'question exceeds 500 chars' });
  }

  ctx.emit('tool_call', {
    name: 'read_attachment',
    attachment_id: idArg,
    question,
  });

  const supa = serviceClient(env);

  // Resolve prefix → full UUID. Full UUIDs (36 chars) match exactly;
  // shorter inputs get matched by prefix within this conv. UUID prefix
  // search via ilike on the text-cast id — the conversation_id filter
  // bounds the row count, so this stays cheap without a dedicated index.
  let fullId = idArg;
  if (!UUID_RE.test(idArg)) {
    const { data: matches, error: matchErr } = await supa
      .from('attachments')
      .select('id')
      .eq('conversation_id', ctx.conversationId)
      .ilike('id::text' as never, `${idArg.toLowerCase()}%`);
    if (matchErr) {
      ctx.emit('tool_result', { name: 'read_attachment', error: matchErr.message });
      return JSON.stringify({ error: `database: ${matchErr.message}` });
    }
    const rows = (matches ?? []) as Array<{ id: string }>;
    if (rows.length === 0) {
      ctx.emit('tool_result', { name: 'read_attachment', error: 'no match' });
      return JSON.stringify({
        error: `no attachment in this conversation matches prefix "${idArg}"`,
      });
    }
    if (rows.length > 1) {
      ctx.emit('tool_result', { name: 'read_attachment', error: 'ambiguous' });
      return JSON.stringify({
        error: `prefix "${idArg}" matches ${rows.length} attachments; pass a longer prefix or the full UUID`,
        candidates: rows.map((r) => r.id),
      });
    }
    fullId = rows[0]!.id;
  }

  const result = await readAttachmentForTool(
    {
      supa,
      env,
      conversationId: ctx.conversationId,
      userId: ctx.userId,
      mainModelSlug: ctx.botModelId,
      visionOverride: ctx.visionOverride,
    },
    fullId,
    question,
  );

  if ('error' in result) {
    ctx.emit('tool_result', {
      name: 'read_attachment',
      attachment_id: fullId,
      error: result.error,
    });
    return JSON.stringify({ error: result.error });
  }
  ctx.emit('tool_result', {
    name: 'read_attachment',
    attachment_id: fullId,
    chars: result.answer.length,
  });
  return JSON.stringify({ attachment_id: fullId, answer: result.answer });
}
