// Pure type-only declarations for the web-tool return shapes. Lives here
// (not in web.ts) so envelope-loop.ts can `import type` them without
// dragging in worker-only `Env` bindings.

export interface WebSearchResult {
  url: string;
  title: string;
  snippet: string;
}

export interface WebReadResult {
  url: string;
  title: string;
  content: string;
}
