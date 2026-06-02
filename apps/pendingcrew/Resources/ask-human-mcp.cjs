#!/usr/bin/env node
// PendingCrew `ask_human` MCP server — T4.5 人在回路交互（spec §10）。
//
// 一个 stdio MCP server，由 runner 经 `--mcp-config` 随 session 一起拉起。
// 暴露一个 `ask_human` 工具：把问题 POST 到 edge 发起一次交互，**阻塞** long-poll
// 等人类回复，拿到回复返回给 agent。agent 在 auto/bypass 跑、绝大多数不打扰人；
// 只有真要人介入（要授权 / 问问题 / 要判断）时才调这个工具。
//
// 配置经 env 传入（mcp.json 的 server.env，由 InteractionChannel 写）：
//   PC_EDGE_URL    edge base，如 https://api.pendingname.com
//   PC_TOKEN       device-grant bearer（pdg_…，runner:write）
//   PC_SESSION_ID  crew session uuid
//
// 纯 Node（≥18，用全局 fetch），无第三方依赖。机制已 spike 验通（阻塞 MCP 工具
// 在 headless `claude -p --mcp-config` 下可用，见 docs/crew-runner-steering.md /
// 交互 plan P2）。

'use strict';

const EDGE = process.env.PC_EDGE_URL || '';
const TOKEN = process.env.PC_TOKEN || '';
const SESSION = process.env.PC_SESSION_ID || '';
const POLL_MS = Number(process.env.PC_POLL_MS || '2000');

const send = (m) => process.stdout.write(JSON.stringify(m) + '\n');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function askHuman(question) {
  if (!EDGE || !TOKEN || !SESSION) {
    throw new Error('ask_human not configured (missing PC_EDGE_URL / PC_TOKEN / PC_SESSION_ID)');
  }
  // 1) 发起交互
  const raise = await fetch(`${EDGE}/v1/sessions/${SESSION}/interactions`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${TOKEN}` },
    body: JSON.stringify({ question }),
  });
  if (!raise.ok) throw new Error(`raise failed: HTTP ${raise.status}`);
  const raised = await raise.json();
  const requestId = raised && raised.requestId;
  if (!requestId) throw new Error('edge returned no requestId');

  // 2) long-poll 等回复（阻塞）
  for (;;) {
    await sleep(POLL_MS);
    let poll;
    try {
      poll = await fetch(`${EDGE}/v1/sessions/${SESSION}/interactions/${requestId}`, {
        headers: { authorization: `Bearer ${TOKEN}` },
      });
    } catch {
      continue; // 瞬断，继续轮询
    }
    if (!poll.ok) continue;
    const state = await poll.json();
    if (state && state.status === 'answered') {
      return (state.replyText && String(state.replyText)) || '(human answered with no text)';
    }
    if (state && state.status && state.status !== 'pending') {
      // expired / cancelled 等终态 —— 不再等
      return `(interaction ${state.status} without an answer)`;
    }
    // 'pending' → 继续
  }
}

const TOOL = {
  name: 'ask_human',
  description:
    'Ask the responsible human a question and BLOCK until they answer. Use ONLY when you genuinely need human input you cannot resolve yourself — a decision/choice, an authorization (e.g. enabling computer-use), or a clarification. Do not use it for routine work. Returns the human\'s reply as text.',
  inputSchema: {
    type: 'object',
    properties: { question: { type: 'string', description: 'The question or request to put to the human.' } },
    required: ['question'],
  },
};

require('readline')
  .createInterface({ input: process.stdin })
  .on('line', async (line) => {
    let req;
    try { req = JSON.parse(line); } catch { return; }
    const { id, method, params } = req;
    if (method === 'initialize') {
      send({ jsonrpc: '2.0', id, result: { protocolVersion: '2024-11-05', capabilities: { tools: {} }, serverInfo: { name: 'pendingcrew', version: '1' } } });
    } else if (method === 'tools/list') {
      send({ jsonrpc: '2.0', id, result: { tools: [TOOL] } });
    } else if (method === 'tools/call') {
      if (params && params.name === 'ask_human') {
        try {
          const answer = await askHuman((params.arguments && params.arguments.question) || '');
          send({ jsonrpc: '2.0', id, result: { content: [{ type: 'text', text: answer }] } });
        } catch (e) {
          send({ jsonrpc: '2.0', id, result: { content: [{ type: 'text', text: `(ask_human failed: ${e && e.message})` }], isError: true } });
        }
      } else {
        send({ jsonrpc: '2.0', id, error: { code: -32601, message: 'unknown tool' } });
      }
    } else if (id !== undefined) {
      send({ jsonrpc: '2.0', id, result: {} });
    }
  });
