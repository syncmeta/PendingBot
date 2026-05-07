# scroll-lab

本地 web 面板，用来打磨 [奏折 (scroll) 功能](../edge/src/lib/scroll-loop.ts) 的 prompt 和 agent loop。**不部署、不进 app**。

## 启动

```bash
cd apps/scroll-lab
bun install            # 一次
bun run dev            # 开 vite (5174) + tsx watch api (5175)
```

打开 <http://localhost:5174>。

API key 来自 `~/.config/pendingbot/.dev.vars`（与 [scroll-replay CLI](../edge/scripts/scroll-replay.ts) 共用）：
- `OPENROUTER_API_KEY`（必需）
- `BRAVE_API_KEY` / `TAVILY_API_KEY` / `EXA_API_KEY` / `SERPER_API_KEY`（搜索，按需）
- `FIRECRAWL_API_KEY`（抓取，按需，Tavily/Exa 也支持抓取且 key 跟搜索共用）

## 面板能干什么

1. **左侧 Settings** — 切模型 / 搜索提供商 / 抓取提供商 / turn cap / stub 工具开关 / 加载 fixture
2. **中间 Editors** — 直接改 system prompt、injected prompt、memory、history（任何字段都临时改、不动磁盘）
3. **右侧 Output**
   - 实时 stream 每个 turn：assistant 回复、tool_call、tool_result
   - **Token 表**——每 turn 的 input/output 增量 + 累积，看哪一步吃 token 多
   - 最终文章 + 标题 / 摘要 / notes / visited URLs
   - 如果模型来自 OpenRouter，运行结束后从 `/api/v1/generation?id=…` 拉权威 USD 成本

## 我改了 prompt / loop，怎么"装回去"

prompt 的"原版"来自 [apps/edge/prompts/scroll.md](../edge/prompts/scroll.md) 和 [scroll-injected.md](../edge/prompts/scroll-injected.md)；面板里改过的版本只在内存中，不写盘。打磨满意后，**手动把改好的内容粘回那两个文件**，commit、merge、deploy 流程同 [CLAUDE.md](../../CLAUDE.md) 的发布约定。

loop 行为改在 [apps/edge/src/lib/scroll-loop.ts](../edge/src/lib/scroll-loop.ts) ——**面板 server 直接 import 那个文件**，所以你 hot-reload tsx 看到的就是生产 loop 的真实行为。

## fixtures

放在 [apps/scroll-lab/fixtures/](./fixtures/) 或 [apps/edge/scripts/fixtures/](../edge/scripts/fixtures/) — 两个目录都会被加载。

格式：

```json
{
  "model": "anthropic/claude-haiku-4-5",
  "memory": "可选——bot 长期观察",
  "history": [
    { "role": "user", "content": "..." },
    { "role": "bot",  "content": "..." }
  ]
}
```

也接受 `{ "messages": [...] }` 或裸数组 `[{role, content}, ...]`。
