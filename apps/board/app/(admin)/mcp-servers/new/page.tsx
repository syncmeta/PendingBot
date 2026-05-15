import { McpServerForm } from '../_form';
import { createMcpServer } from '../actions';

export default function NewMcpServerPage() {
  return (
    <main className="container max-w-2xl py-10 space-y-6">
      <h1 className="text-2xl font-bold tracking-tight">新增 MCP 服务</h1>
      <McpServerForm action={createMcpServer} submitLabel="创建" />
    </main>
  );
}
