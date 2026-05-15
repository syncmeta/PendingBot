import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import type { ChatCompletionTool } from 'openai/resources/chat/completions';
import { contextToMeta, type McpContext } from './context';
import { internalMcpServer } from './server';

// Result envelope for callTool, matching MCP CallToolResult shape.
export type McpCallResult = Awaited<ReturnType<Client['callTool']>>;

type ConnectionState =
  | { stage: 'idle' }
  | { stage: 'connecting'; promise: Promise<void> }
  | { stage: 'ready' };

// One McpClientManager instance per Worker isolate. Holds the live
// in-memory Client paired to internalMcpServer (and, later, HTTP clients
// for Tavily/Exa). Connection is lazy: first call drives setup, concurrent
// callers await the same promise.
class McpClientManager {
  private selfClient = new Client({ name: 'pendingbot-loop', version: '0.1.0' });
  private state: ConnectionState = { stage: 'idle' };

  private async ensureConnected(): Promise<void> {
    if (this.state.stage === 'ready') return;
    if (this.state.stage === 'connecting') {
      await this.state.promise;
      return;
    }
    const promise = (async () => {
      const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
      await Promise.all([
        internalMcpServer.connect(serverTransport),
        this.selfClient.connect(clientTransport),
      ]);
    })();
    this.state = { stage: 'connecting', promise };
    try {
      await promise;
      this.state = { stage: 'ready' };
    } catch (err) {
      this.state = { stage: 'idle' };
      throw err;
    }
  }

  async getAITools(
    _ctx: McpContext,
    _opts?: { skill?: boolean; isGroup?: boolean },
  ): Promise<ChatCompletionTool[]> {
    await this.ensureConnected();
    const { tools } = await this.selfClient.listTools();
    return tools.map<ChatCompletionTool>((t) => ({
      type: 'function',
      function: {
        name: t.name,
        description: t.description ?? '',
        parameters: t.inputSchema as Record<string, unknown>,
      },
    }));
  }

  async callTool(
    name: string,
    args: Record<string, unknown>,
    ctx: McpContext,
  ): Promise<McpCallResult> {
    await this.ensureConnected();
    return await this.selfClient.callTool({
      name,
      arguments: args,
      _meta: contextToMeta(ctx),
    });
  }
}

// Per-isolate singleton. Initialized lazily on first use.
export const mcpClient = new McpClientManager();
