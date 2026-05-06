import { useEffect, useState } from 'react';
import {
  fetchConfig,
  fetchFixture,
  fetchFixtures,
  fetchOpenrouterCost,
  fetchPrompts,
  runStream,
} from './api';
import { clearAll, useLocalStorage } from './storage';
import type {
  ConfigResponse,
  FixtureMeta,
  HistoryMsg,
  ResultEvent,
  ScrapeProvider,
  SearchProvider,
  StartEvent,
  TurnEvent,
} from './types';

type RunStatus = 'idle' | 'running' | 'done' | 'error';

export function App() {
  // ── Server-side config ────────────────────────────────────────────
  const [cfg, setCfg] = useState<ConfigResponse | null>(null);
  const [fixtures, setFixtures] = useState<FixtureMeta[]>([]);
  const [bootError, setBootError] = useState<string | null>(null);

  // ── Run inputs (editable in UI; persisted to localStorage) ────────
  // Anything you'd hate to retype after a refresh lives in storage.ts.
  const [model, setModel] = useLocalStorage<string>('model', '');
  const [searchProvider, setSearchProvider] = useLocalStorage<SearchProvider>('searchProvider', 'brave');
  const [scrapeProvider, setScrapeProvider] = useLocalStorage<ScrapeProvider>('scrapeProvider', 'firecrawl');
  const [turnCap, setTurnCap] = useLocalStorage<number>('turnCap', 8);
  const [stubSearch, setStubSearch] = useLocalStorage<boolean>('stubSearch', false);
  const [stubFetch, setStubFetch] = useLocalStorage<boolean>('stubFetch', false);

  // Prompts use null as the "not yet hydrated" sentinel so we can tell
  // first-launch (use disk) from edited-then-cleared (keep empty).
  const [systemPrompt, setSystemPrompt] = useLocalStorage<string | null>('systemPrompt', null);
  const [injectedPrompt, setInjectedPrompt] = useLocalStorage<string | null>('injectedPrompt', null);
  const [systemPromptOriginal, setSystemPromptOriginal] = useState<string>('');
  const [injectedPromptOriginal, setInjectedPromptOriginal] = useState<string>('');

  const [memory, setMemory] = useLocalStorage<string>('memory', '');
  const [history, setHistory] = useLocalStorage<HistoryMsg[]>('history', [
    { role: 'user', content: '' },
    { role: 'bot', content: '' },
  ]);

  // ── Run output ────────────────────────────────────────────────────
  const [status, setStatus] = useState<RunStatus>('idle');
  const [start, setStart] = useState<StartEvent | null>(null);
  const [turns, setTurns] = useState<TurnEvent[]>([]);
  const [result, setResult] = useState<ResultEvent | null>(null);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const [costUSD, setCostUSD] = useState<number | null>(null);

  // ── Boot: load /api/config, /api/prompts, /api/fixtures ───────────
  // Defaults from server *only* fill blanks — saved values from
  // localStorage (model, prompt edits, etc.) take precedence so a
  // refresh doesn't blow away whatever you were just tweaking.
  useEffect(() => {
    Promise.all([fetchConfig(), fetchPrompts(), fetchFixtures()])
      .then(([c, p, f]) => {
        setCfg(c);
        setSystemPromptOriginal(p.system);
        setInjectedPromptOriginal(p.injected);
        setFixtures(f);
        if (!model) setModel(c.defaultModel);
        if (systemPrompt === null) setSystemPrompt(p.system);
        if (injectedPrompt === null) setInjectedPrompt(p.injected);
      })
      .catch((e: Error) => setBootError(e.message));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // ── Fixture loading ───────────────────────────────────────────────
  async function loadFixture(id: string): Promise<void> {
    if (!id) return;
    const fx = await fetchFixture(id);
    const h = (fx.history ?? fx.messages ?? []) as HistoryMsg[];
    if (h.length) setHistory(h);
    if (fx.memory) setMemory(fx.memory);
    if (fx.model) setModel(fx.model);
  }

  // ── Run ───────────────────────────────────────────────────────────
  async function run(): Promise<void> {
    if (systemPrompt === null || injectedPrompt === null) {
      setErrorMsg('prompts still loading — try again in a moment');
      return;
    }
    setStatus('running');
    setStart(null);
    setTurns([]);
    setResult(null);
    setErrorMsg(null);
    setCostUSD(null);
    try {
      await runStream(
        {
          model,
          systemPrompt,
          injectedPrompt,
          history: history.filter((m) => m.content.trim()),
          memory: memory.trim() || undefined,
          searchProvider,
          scrapeProvider,
          stubSearch,
          stubFetch,
          turns: turnCap,
        },
        {
          onStart: (e) => setStart(e),
          onTurn: (e) => setTurns((prev) => [...prev, e]),
          onResult: (e) => {
            setResult(e);
            setStatus('done');
            // OpenRouter authoritative USD cost (best-effort).
            if (e.generationId) {
              fetchOpenrouterCost(e.generationId).then((j) => {
                if (j?.data?.total_cost != null) setCostUSD(j.data.total_cost);
              });
            }
          },
          onError: (msg) => {
            setErrorMsg(msg);
            setStatus('error');
          },
        },
      );
    } catch (e) {
      setErrorMsg((e as Error).message);
      setStatus('error');
    }
  }

  if (bootError) {
    return (
      <div className="boot-error">
        服务器没起来? <code>{bootError}</code>
      </div>
    );
  }
  if (!cfg) return <div className="boot">loading…</div>;

  return (
    <div className="app">
      <Header status={status} result={result} costUSD={costUSD} onRun={run} />
      <main className="layout">
        <section className="settings">
          <Settings
            cfg={cfg}
            model={model}
            setModel={setModel}
            searchProvider={searchProvider}
            setSearchProvider={setSearchProvider}
            scrapeProvider={scrapeProvider}
            setScrapeProvider={setScrapeProvider}
            turnCap={turnCap}
            setTurnCap={setTurnCap}
            stubSearch={stubSearch}
            setStubSearch={setStubSearch}
            stubFetch={stubFetch}
            setStubFetch={setStubFetch}
            fixtures={fixtures}
            onLoadFixture={loadFixture}
          />
        </section>
        <section className="editors">
          <PromptsBlock
            label="System (prompts/scroll.md)"
            value={systemPrompt}
            setValue={setSystemPrompt}
            original={systemPromptOriginal}
          />
          <PromptsBlock
            label="Injected (prompts/scroll-injected.md)"
            value={injectedPrompt}
            setValue={setInjectedPrompt}
            original={injectedPromptOriginal}
          />
          <MemoryBlock value={memory} setValue={setMemory} />
          <HistoryEditor history={history} setHistory={setHistory} />
        </section>
        <section className="output">
          <Output start={start} turns={turns} result={result} errorMsg={errorMsg} />
        </section>
      </main>
    </div>
  );
}

// ─────────── Components ────────────────────────────────────────────

function Header(props: {
  status: RunStatus;
  result: ResultEvent | null;
  costUSD: number | null;
  onRun: () => void;
}): JSX.Element {
  function onReset(): void {
    if (!confirm('清空本地保存的所有面板状态（model / prompts / memory / history / 设置）然后刷新?')) return;
    clearAll();
    location.reload();
  }
  return (
    <header className="hdr">
      <div className="title">scroll-lab <span className="dim">— 奏折打磨台</span></div>
      <div className="grow" />
      <div className="status">
        {props.status === 'idle' && <span className="dim">idle</span>}
        {props.status === 'running' && <span className="running">running…</span>}
        {props.status === 'done' && props.result && (
          <span className="done">
            ✓ {props.result.reason}  ·  {props.result.turns}t  ·  {(props.result.elapsedMs / 1000).toFixed(1)}s
            {' '}·  {props.result.usage.total.toLocaleString()} tok
            {props.costUSD != null && `  ·  $${props.costUSD.toFixed(4)}`}
          </span>
        )}
        {props.status === 'error' && <span className="err">error</span>}
      </div>
      <button onClick={onReset} className="wipe" title="清空 localStorage 中的面板状态">
        wipe
      </button>
      <button onClick={props.onRun} disabled={props.status === 'running'} className="run">
        {props.status === 'running' ? '运行中…' : '▶ Run'}
      </button>
    </header>
  );
}

function Settings(p: {
  cfg: ConfigResponse;
  model: string;
  setModel: (m: string) => void;
  searchProvider: SearchProvider;
  setSearchProvider: (p: SearchProvider) => void;
  scrapeProvider: ScrapeProvider;
  setScrapeProvider: (p: ScrapeProvider) => void;
  turnCap: number;
  setTurnCap: (n: number) => void;
  stubSearch: boolean;
  setStubSearch: (b: boolean) => void;
  stubFetch: boolean;
  setStubFetch: (b: boolean) => void;
  fixtures: FixtureMeta[];
  onLoadFixture: (id: string) => Promise<void>;
}): JSX.Element {
  const k = p.cfg.keysPresent;
  return (
    <div className="card">
      <h3>设置</h3>

      <label>模型</label>
      <select value={p.model} onChange={(e) => p.setModel(e.target.value)}>
        {p.cfg.models.map((m) => (
          <option key={m.model} value={m.model} disabled={m.keyMissing}>
            {m.name}
            {m.direct ? ' · direct' : ''}
            {m.keyMissing ? ' (no key)' : ''}
          </option>
        ))}
        <option value="">— custom (OpenRouter) —</option>
      </select>
      {!p.cfg.models.find((m) => m.model === p.model) && (
        <input
          className="custom-model"
          placeholder="自定义 model id (例: openai/gpt-4o-mini)"
          value={p.model}
          onChange={(e) => p.setModel(e.target.value)}
        />
      )}

      <label>搜索提供商</label>
      <select value={p.searchProvider} onChange={(e) => p.setSearchProvider(e.target.value as SearchProvider)}>
        {p.cfg.searchProviders.map((s) => (
          <option key={s} value={s} disabled={!k[s as keyof typeof k]}>
            {s} {!k[s as keyof typeof k] ? '(no key)' : ''}
          </option>
        ))}
      </select>

      <label>抓取提供商</label>
      <select value={p.scrapeProvider} onChange={(e) => p.setScrapeProvider(e.target.value as ScrapeProvider)}>
        {p.cfg.scrapeProviders.map((s) => (
          <option key={s} value={s} disabled={!k[s as keyof typeof k]}>
            {s} {!k[s as keyof typeof k] ? '(no key)' : ''}
          </option>
        ))}
      </select>

      <label>Turn cap</label>
      <input
        type="number"
        min={1}
        max={30}
        value={p.turnCap}
        onChange={(e) => p.setTurnCap(Number(e.target.value))}
      />

      <label className="check">
        <input type="checkbox" checked={p.stubSearch} onChange={(e) => p.setStubSearch(e.target.checked)} />
        stub web_search (返回空)
      </label>
      <label className="check">
        <input type="checkbox" checked={p.stubFetch} onChange={(e) => p.setStubFetch(e.target.checked)} />
        stub fetch_url (返回占位文)
      </label>

      <hr />
      <label>Fixture</label>
      <select onChange={(e) => p.onLoadFixture(e.target.value)} defaultValue="">
        <option value="">— 选一个加载 —</option>
        {p.fixtures.map((f) => (
          <option key={f.id} value={f.id}>{f.id}</option>
        ))}
      </select>
    </div>
  );
}

function PromptsBlock(p: {
  label: string;
  value: string | null;
  setValue: (v: string) => void;
  original: string;
}): JSX.Element {
  const current = p.value ?? '';
  const dirty = p.value !== null && p.value !== p.original && p.original !== '';
  return (
    <details className="block" open={false}>
      <summary>
        {p.label} {dirty && <span className="dirty">· edited</span>}
        {dirty && (
          <button
            className="reset"
            onClick={(e) => {
              e.preventDefault();
              p.setValue(p.original);
            }}
          >
            reset
          </button>
        )}
      </summary>
      <textarea value={current} onChange={(e) => p.setValue(e.target.value)} rows={12} />
    </details>
  );
}

function MemoryBlock(p: { value: string; setValue: (v: string) => void }): JSX.Element {
  return (
    <details className="block" open={false}>
      <summary>Memory <span className="dim">(可选, bot 长期观察)</span></summary>
      <textarea value={p.value} onChange={(e) => p.setValue(e.target.value)} rows={4} />
    </details>
  );
}

function HistoryEditor(p: {
  history: HistoryMsg[];
  setHistory: (h: HistoryMsg[]) => void;
}): JSX.Element {
  function update(i: number, patch: Partial<HistoryMsg>): void {
    p.setHistory(p.history.map((m, idx) => (idx === i ? { ...m, ...patch } : m)));
  }
  function remove(i: number): void {
    p.setHistory(p.history.filter((_, idx) => idx !== i));
  }
  function add(role: 'user' | 'bot'): void {
    p.setHistory([...p.history, { role, content: '' }]);
  }
  return (
    <details className="block" open>
      <summary>History <span className="dim">({p.history.length} msgs)</span></summary>
      <div className="hist">
        {p.history.map((m, i) => (
          <div key={i} className={`msg msg-${m.role}`}>
            <select
              value={m.role}
              onChange={(e) => update(i, { role: e.target.value as 'user' | 'bot' })}
            >
              <option value="user">user</option>
              <option value="bot">bot</option>
            </select>
            <textarea
              value={m.content}
              onChange={(e) => update(i, { content: e.target.value })}
              rows={Math.max(2, Math.min(8, Math.ceil(m.content.length / 60)))}
            />
            <button onClick={() => remove(i)} className="x">×</button>
          </div>
        ))}
        <div className="add-row">
          <button onClick={() => add('user')}>+ user</button>
          <button onClick={() => add('bot')}>+ bot</button>
        </div>
      </div>
    </details>
  );
}

function Output(p: {
  start: StartEvent | null;
  turns: TurnEvent[];
  result: ResultEvent | null;
  errorMsg: string | null;
}): JSX.Element {
  return (
    <div className="card">
      <h3>运行</h3>
      {p.errorMsg && <div className="err-box">{p.errorMsg}</div>}
      {p.start && (
        <div className="dim">
          model: <code>{p.start.model}</code> · system: {p.start.systemChars} chars · initial user: {p.start.initialUserChars} chars
        </div>
      )}

      {p.turns.length > 0 && <TokenTable turns={p.turns} />}

      <div className="turns">
        {p.turns.map((t) => (
          <Turn key={t.turn} t={t} />
        ))}
      </div>

      {p.result && <ResultBlock r={p.result} />}
    </div>
  );
}

function TokenTable({ turns }: { turns: TurnEvent[] }): JSX.Element {
  const cum = turns.length ? turns[turns.length - 1].cumulativeUsage : null;
  return (
    <table className="tokens">
      <thead>
        <tr>
          <th>turn</th>
          <th>phase</th>
          <th>Δ in</th>
          <th>Δ out</th>
          <th>cum in</th>
          <th>cum out</th>
        </tr>
      </thead>
      <tbody>
        {turns.map((t) => (
          <tr key={t.turn}>
            <td>{t.turn}</td>
            <td>{t.progress.phase}</td>
            <td className="num">{t.turnUsage.input.toLocaleString()}</td>
            <td className="num">{t.turnUsage.output.toLocaleString()}</td>
            <td className="num dim">{t.cumulativeUsage.input.toLocaleString()}</td>
            <td className="num dim">{t.cumulativeUsage.output.toLocaleString()}</td>
          </tr>
        ))}
        {cum && (
          <tr className="total">
            <td colSpan={2}>total</td>
            <td colSpan={2} />
            <td className="num">{cum.input.toLocaleString()}</td>
            <td className="num">{cum.output.toLocaleString()}</td>
          </tr>
        )}
      </tbody>
    </table>
  );
}

function Turn({ t }: { t: TurnEvent }): JSX.Element {
  return (
    <details className="turn" open>
      <summary>
        turn {t.turn} <span className="dim">phase={t.progress.phase} · in={t.turnUsage.input.toLocaleString()} out={t.turnUsage.output.toLocaleString()}</span>
      </summary>
      {t.newMessages.map((m, i) => {
        if (m.role === 'assistant') {
          return (
            <div key={i} className="m-asst">
              {m.content && <div className="asst-text">{m.content}</div>}
              {m.tool_calls?.map((tc) => (
                <div key={tc.id} className="tool-call">
                  <div className="tc-name">tool_call {tc.function.name}</div>
                  <pre>{tc.function.arguments}</pre>
                </div>
              ))}
            </div>
          );
        }
        return (
          <div key={i} className="m-tool">
            <div className="tc-name">tool_result <span className="dim">id={m.tool_call_id}</span></div>
            <pre>{m.content}</pre>
          </div>
        );
      })}
    </details>
  );
}

function ResultBlock({ r }: { r: ResultEvent }): JSX.Element {
  return (
    <div className="result">
      <h3>结果</h3>
      <div className="result-meta">
        reason: <code>{r.reason}</code> · turns: {r.turns} · elapsed: {(r.elapsedMs / 1000).toFixed(1)}s ·
        notes: {r.progress.notes.length} · urls: {r.progress.visited_urls.length} · plan rounds: {r.progress.plan_rounds}
      </div>
      {r.title && <div>标题: <strong>{r.title}</strong></div>}
      {r.summary && <div>摘要: <em>{r.summary}</em></div>}
      {r.finalArticle ? (
        <pre className="article">{r.finalArticle}</pre>
      ) : (
        <div className="dim">(空奏折 — 生产环境下会被删除)</div>
      )}
      {r.progress.notes.length > 0 && (
        <details>
          <summary>notes ({r.progress.notes.length})</summary>
          <ul>
            {r.progress.notes.map((n, i) => (
              <li key={i}>
                {n.text}
                {n.source && <a href={n.source} target="_blank" rel="noreferrer"> [src]</a>}
              </li>
            ))}
          </ul>
        </details>
      )}
      {r.progress.visited_urls.length > 0 && (
        <details>
          <summary>visited urls ({r.progress.visited_urls.length})</summary>
          <ul>
            {r.progress.visited_urls.map((u) => (
              <li key={u}><a href={u} target="_blank" rel="noreferrer">{u}</a></li>
            ))}
          </ul>
        </details>
      )}
    </div>
  );
}
