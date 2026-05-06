// Mirror of the SSE event payloads from server/index.ts.

export type SearchProvider = 'brave' | 'tavily' | 'exa' | 'serper';
export type ScrapeProvider = 'firecrawl' | 'tavily' | 'exa';

export interface ModelEntry {
  name: string;
  model: string;
  direct?: boolean;       // bypasses OpenRouter (e.g. DeepSeek 官方)
  keyMissing?: boolean;   // no API key configured → un-runnable
}

export interface ConfigResponse {
  models: ModelEntry[];
  defaultModel: string;
  searchProviders: SearchProvider[];
  scrapeProviders: ScrapeProvider[];
  keysPresent: {
    openrouter: boolean;
    brave: boolean;
    tavily: boolean;
    exa: boolean;
    serper: boolean;
    firecrawl: boolean;
    deepseek?: boolean;
  };
}

export interface PromptsResponse {
  system: string;
  injected: string;
}

export interface FixtureMeta {
  id: string;
  path: string;
}

export interface FixtureFile {
  history?: HistoryMsg[];
  messages?: HistoryMsg[];
  model?: string;
  memory?: string;
}

export type Role = 'user' | 'bot' | 'human';
export interface HistoryMsg {
  role: Role;
  content: string;
}

export interface ToolCall {
  id: string;
  type?: 'function';
  function: { name: string; arguments: string };
}

export interface AssistantMessage {
  role: 'assistant';
  content: string | null;
  tool_calls?: ToolCall[];
}
export interface ToolMessage {
  role: 'tool';
  tool_call_id: string;
  content: string;
}
export type LoopMessage = AssistantMessage | ToolMessage;

export interface NoteEntry {
  text: string;
  source?: string;
  t: number;
}
export interface ProgressState {
  phase: 'gather' | 'plan' | 'research' | 'compose' | 'done' | 'error';
  notes: NoteEntry[];
  visited_urls: string[];
  plan_rounds: number;
}

export interface TurnEvent {
  turn: number;
  progress: ProgressState;
  newMessages: LoopMessage[];
  turnUsage: { input: number; output: number; total: number };
  cumulativeUsage: { input: number; output: number; total: number };
  generationId?: string;
}

export interface ResultEvent {
  reason: 'final' | 'turn_cap' | 'wall_cap' | 'cancelled' | 'no_choice';
  turns: number;
  elapsedMs: number;
  usage: { input: number; output: number; total: number };
  generationId?: string;
  progress: ProgressState;
  finalArticle: string;
  title: string | null;
  summary: string | null;
}

export interface StartEvent {
  model: string;
  systemChars: number;
  initialUserChars: number;
}
