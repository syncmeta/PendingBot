import { useEffect, useRef, useState, type MouseEvent } from 'react';
import {
  fetchConfig,
  fetchFixture,
  fetchFixtures,
  fetchOpenrouterCost,
  fetchPrompts,
  fetchRun,
  fetchRunsList,
  runStream,
  savePrompts,
  type RunSummary,
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
  const [collaboratorModel, setCollaboratorModel] = useLocalStorage<string>('collaboratorModel', '');
  const [writeModel, setWriteModel] = useLocalStorage<string>('writeModel', '');
  const [showTurnsRemaining, setShowTurnsRemaining] = useLocalStorage<boolean>('showTurnsRemaining', false);
  const [searchProvider, setSearchProvider] = useLocalStorage<SearchProvider>('searchProvider', 'brave');
  const [scrapeProvider, setScrapeProvider] = useLocalStorage<ScrapeProvider>('scrapeProvider', 'firecrawl');
  const [turnCap, setTurnCap] = useLocalStorage<number>('turnCap', 8);
  const [stubSearch, setStubSearch] = useLocalStorage<boolean>('stubSearch', false);
  const [stubFetch, setStubFetch] = useLocalStorage<boolean>('stubFetch', false);
  const [writePhaseEnabled, setWritePhaseEnabled] = useLocalStorage<boolean>('writePhaseEnabled', false);

  // Prompts use null as the "not yet hydrated" sentinel so we can tell
  // first-launch (use disk) from edited-then-cleared (keep empty).
  const [systemPrompt, setSystemPrompt] = useLocalStorage<string | null>('systemPrompt', null);
  const [injectedPrompt, setInjectedPrompt] = useLocalStorage<string | null>('injectedPrompt', null);
  const [writePrompt, setWritePrompt] = useLocalStorage<string | null>('writePrompt', null);
  const [collaboratorPrompt, setCollaboratorPrompt] = useLocalStorage<string | null>('collaboratorPrompt', null);
  const [systemPromptOriginal, setSystemPromptOriginal] = useState<string>('');
  const [injectedPromptOriginal, setInjectedPromptOriginal] = useState<string>('');
  const [writePromptOriginal, setWritePromptOriginal] = useState<string>('');
  const [collaboratorPromptOriginal, setCollaboratorPromptOriginal] = useState<string>('');

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
  const [runs, setRuns] = useState<RunSummary[]>([]);
  // Abort controller for the active /api/run stream — Stop button calls
  // abort() which closes the SSE connection; the server's request signal
  // fires and runScrollLoop's isCancelled returns true on next iteration.
  const abortRef = useRef<AbortController | null>(null);

  // ── Boot: load /api/config, /api/prompts, /api/fixtures ───────────
  // Defaults from server *only* fill blanks — saved values from
  // localStorage (model, prompt edits, etc.) take precedence so a
  // refresh doesn't blow away whatever you were just tweaking.
  useEffect(() => {
    Promise.all([fetchConfig(), fetchPrompts(), fetchFixtures(), fetchRunsList()])
      .then(([c, p, f, r]) => {
        setCfg(c);
        setSystemPromptOriginal(p.system);
        setInjectedPromptOriginal(p.injected);
        setWritePromptOriginal(p.write);
        setCollaboratorPromptOriginal(p.collaborator);
        setFixtures(f);
        setRuns(r);
        if (!model) setModel(c.defaultModel);
        if (systemPrompt === null) setSystemPrompt(p.system);
        if (injectedPrompt === null) setInjectedPrompt(p.injected);
        if (writePrompt === null) setWritePrompt(p.write);
        if (collaboratorPrompt === null) setCollaboratorPrompt(p.collaborator);
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

  // ── Run / Stop ────────────────────────────────────────────────────
  // resumeFromRunId set ⇒ "继续 N 轮" against an existing run; the
  // server appends turns to that run's saved file. additionalTurns
  // overrides turnCap when resuming.
  async function run(opts?: { resumeFromRunId?: string; additionalTurns?: number }): Promise<void> {
    if (systemPrompt === null || injectedPrompt === null) {
      setErrorMsg('prompts still loading — try again in a moment');
      return;
    }
    setStatus('running');
    if (!opts?.resumeFromRunId) {
      // Fresh run resets the output area; resume keeps prior turns
      // visible while new ones stream in.
      setStart(null);
      setTurns([]);
      setResult(null);
    }
    setErrorMsg(null);
    setCostUSD(null);
    const controller = new AbortController();
    abortRef.current = controller;
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
          turns: opts?.additionalTurns ?? turnCap,
          collaboratorModel: collaboratorModel || undefined,
          collaboratorPrompt:
            collaboratorModel && collaboratorPrompt && collaboratorPrompt.trim()
              ? collaboratorPrompt
              : undefined,
          // Phase 2 only kicks in when both the toggle is on AND a
          // prompt is present. writeModel falls back to main `model`
          // server-side when empty.
          writeModel:
            writePhaseEnabled && writeModel ? writeModel : undefined,
          writePhasePrompt:
            writePhaseEnabled && writePrompt && writePrompt.trim()
              ? writePrompt
              : undefined,
          showTurnsRemaining,
          resumeFromRunId: opts?.resumeFromRunId,
        },
        {
          signal: controller.signal,
          onStart: (e) => setStart(e),
          onTurn: (e) => setTurns((prev) => [...prev, e]),
          onResult: (e) => {
            setResult(e);
            setStatus('done');
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
      const msg = (e as Error).message ?? String(e);
      // AbortError = user pressed Stop — that's not a failure.
      if ((e as Error).name === 'AbortError' || msg.includes('aborted')) {
        setStatus('done');
      } else {
        setErrorMsg(msg);
        setStatus('error');
      }
    } finally {
      abortRef.current = null;
      // Server persisted the run; refresh the sidebar so it shows up.
      refreshRuns();
    }
  }

  function stop(): void {
    abortRef.current?.abort();
  }

  // ── Prompt save-to-disk ───────────────────────────────────────────
  async function saveSystemPromptToDisk(): Promise<void> {
    if (systemPrompt === null) return;
    await savePrompts({ system: systemPrompt });
    setSystemPromptOriginal(systemPrompt);
  }
  async function saveInjectedPromptToDisk(): Promise<void> {
    if (injectedPrompt === null) return;
    await savePrompts({ injected: injectedPrompt });
    setInjectedPromptOriginal(injectedPrompt);
  }
  async function saveWritePromptToDisk(): Promise<void> {
    if (writePrompt === null) return;
    await savePrompts({ write: writePrompt });
    setWritePromptOriginal(writePrompt);
  }
  async function saveCollaboratorPromptToDisk(): Promise<void> {
    if (collaboratorPrompt === null) return;
    await savePrompts({ collaborator: collaboratorPrompt });
    setCollaboratorPromptOriginal(collaboratorPrompt);
  }

  // ── Run history ───────────────────────────────────────────────────
  async function refreshRuns(): Promise<void> {
    try {
      const list = await fetchRunsList();
      setRuns(list);
    } catch {
      /* fine */
    }
  }
  async function loadRun(id: string): Promise<void> {
    type SavedRun = {
      input: {
        model: string;
        collaboratorModel?: string;
        collaboratorPrompt?: string;
        writeModel?: string;
        writePhasePrompt?: string;
        showTurnsRemaining?: boolean;
        searchProvider: SearchProvider;
        scrapeProvider: ScrapeProvider;
        stubSearch: boolean;
        stubFetch: boolean;
        turns: number | null;
        memory: string;
        history: HistoryMsg[];
        systemPrompt: string;
        injectedPrompt: string;
      };
      start?: { systemChars: number; initialUserChars: number };
      turns: TurnEvent[];
      result: ResultEvent | null;
      error: string | null;
    };
    const data = (await fetchRun(id)) as SavedRun;
    setModel(data.input.model);
    setCollaboratorModel(data.input.collaboratorModel ?? '');
    if (data.input.collaboratorPrompt) setCollaboratorPrompt(data.input.collaboratorPrompt);
    setWriteModel(data.input.writeModel ?? '');
    setWritePhaseEnabled(!!data.input.writePhasePrompt);
    if (data.input.writePhasePrompt) setWritePrompt(data.input.writePhasePrompt);
    setShowTurnsRemaining(!!data.input.showTurnsRemaining);
    setSearchProvider(data.input.searchProvider);
    setScrapeProvider(data.input.scrapeProvider);
    setStubSearch(data.input.stubSearch);
    setStubFetch(data.input.stubFetch);
    if (data.input.turns) setTurnCap(data.input.turns);
    setMemory(data.input.memory);
    setHistory(data.input.history);
    setSystemPrompt(data.input.systemPrompt);
    setInjectedPrompt(data.input.injectedPrompt);
    setStart({
      runId: id,
      model: data.input.model,
      systemChars: data.start?.systemChars ?? data.input.systemPrompt.length,
      initialUserChars: data.start?.initialUserChars ?? 0,
    });
    setTurns(data.turns);
    setResult(data.result);
    setErrorMsg(data.error);
    setStatus(data.error ? 'error' : data.result ? 'done' : 'idle');
    setCostUSD(null);
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
      <Header
        status={status}
        result={result}
        costUSD={costUSD}
        onRun={run}
        onStop={stop}
      />
      <main className="layout">
        <section className="settings">
          <RunsList runs={runs} onLoad={loadRun} onRefresh={refreshRuns} />
          <Settings
            cfg={cfg}
            model={model}
            setModel={setModel}
            collaboratorModel={collaboratorModel}
            setCollaboratorModel={setCollaboratorModel}
            writeModel={writeModel}
            setWriteModel={setWriteModel}
            writePhaseEnabled={writePhaseEnabled}
            setWritePhaseEnabled={setWritePhaseEnabled}
            showTurnsRemaining={showTurnsRemaining}
            setShowTurnsRemaining={setShowTurnsRemaining}
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
            onSaveToDisk={saveSystemPromptToDisk}
          />
          <PromptsBlock
            label="Injected (prompts/scroll-injected.md)"
            value={injectedPrompt}
            setValue={setInjectedPrompt}
            original={injectedPromptOriginal}
            onSaveToDisk={saveInjectedPromptToDisk}
          />
          <PromptsBlock
            label={`Collaborator (prompts/scroll-collaborator.md)${collaboratorModel ? '' : ' · 协作者模型未选'}`}
            value={collaboratorPrompt}
            setValue={setCollaboratorPrompt}
            original={collaboratorPromptOriginal}
            onSaveToDisk={saveCollaboratorPromptToDisk}
          />
          <PromptsBlock
            label={`Write phase (prompts/scroll-write.md)${writePhaseEnabled ? '' : ' · 当前未启用'}`}
            value={writePrompt}
            setValue={setWritePrompt}
            original={writePromptOriginal}
            onSaveToDisk={saveWritePromptToDisk}
          />
          <MemoryBlock value={memory} setValue={setMemory} />
          <HistoryEditor history={history} setHistory={setHistory} />
        </section>
        <section className="output">
          <Output
            start={start}
            turns={turns}
            result={result}
            errorMsg={errorMsg}
            status={status}
            onContinue={(n) => run({ resumeFromRunId: result?.runId, additionalTurns: n })}
          />
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
  onStop: () => void;
}): JSX.Element {
  function onReset(): void {
    if (!confirm('清空本地保存的所有面板状态（model / prompts / memory / history / 设置）然后刷新?')) return;
    clearAll();
    location.reload();
  }
  const running = props.status === 'running';
  return (
    <header className="hdr">
      <div className="title">scroll-lab <span className="dim">— 奏折打磨台</span></div>
      <div className="grow" />
      <div className="status">
        {props.status === 'idle' && <span className="dim">idle</span>}
        {running && <span className="running">running…</span>}
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
      {running ? (
        <button onClick={props.onStop} className="stop" title="中止当前 run">
          ■ Stop
        </button>
      ) : (
        <button onClick={props.onRun} className="run">
          ▶ Run
        </button>
      )}
    </header>
  );
}

function Settings(p: {
  cfg: ConfigResponse;
  model: string;
  setModel: (m: string) => void;
  collaboratorModel: string;
  setCollaboratorModel: (m: string) => void;
  writeModel: string;
  setWriteModel: (m: string) => void;
  writePhaseEnabled: boolean;
  setWritePhaseEnabled: (b: boolean) => void;
  showTurnsRemaining: boolean;
  setShowTurnsRemaining: (b: boolean) => void;
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

      <label>主模型 <span className="dim">(写奏折的)</span></label>
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

      <label>协作者模型 <span className="dim">(每轮介入 / 给主探索者反馈)</span></label>
      <select
        value={p.collaboratorModel}
        onChange={(e) => p.setCollaboratorModel(e.target.value)}
      >
        <option value="">— 不用，propose_plan 回固定的"继续" —</option>
        {p.cfg.models.map((m) => (
          <option key={m.model} value={m.model} disabled={m.keyMissing}>
            {m.name}
            {m.direct ? ' · direct' : ''}
            {m.keyMissing ? ' (no key)' : ''}
          </option>
        ))}
      </select>

      <label className="check">
        <input
          type="checkbox"
          checked={p.showTurnsRemaining}
          onChange={(e) => p.setShowTurnsRemaining(e.target.checked)}
        />
        让模型知道剩余 turn 数
      </label>

      <label className="check">
        <input
          type="checkbox"
          checked={p.writePhaseEnabled}
          onChange={(e) => p.setWritePhaseEnabled(e.target.checked)}
        />
        启用写文章阶段（两段式）
      </label>

      <label>写文章模型 <span className="dim">(phase 2; 留空 = 跟主模型一致)</span></label>
      <select
        value={p.writeModel}
        onChange={(e) => p.setWriteModel(e.target.value)}
        disabled={!p.writePhaseEnabled}
      >
        <option value="">— 跟主模型一致 —</option>
        {p.cfg.models.map((m) => (
          <option key={m.model} value={m.model} disabled={m.keyMissing}>
            {m.name}
            {m.direct ? ' · direct' : ''}
            {m.keyMissing ? ' (no key)' : ''}
          </option>
        ))}
      </select>

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
  onSaveToDisk: () => Promise<void>;
}): JSX.Element {
  const current = p.value ?? '';
  const dirty = p.value !== null && p.value !== p.original && p.original !== '';
  const [saving, setSaving] = useState(false);
  const [saveErr, setSaveErr] = useState<string | null>(null);
  async function handleSave(e: MouseEvent): Promise<void> {
    e.preventDefault();
    setSaving(true);
    setSaveErr(null);
    try {
      await p.onSaveToDisk();
    } catch (err) {
      setSaveErr((err as Error).message ?? String(err));
    } finally {
      setSaving(false);
    }
  }
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
        {dirty && (
          <button className="save" onClick={handleSave} disabled={saving}>
            {saving ? '保存中…' : '💾 save to file'}
          </button>
        )}
      </summary>
      {saveErr && <div className="err-box">{saveErr}</div>}
      <textarea value={current} onChange={(e) => p.setValue(e.target.value)} rows={12} />
    </details>
  );
}

function RunsList(p: {
  runs: RunSummary[];
  onLoad: (id: string) => Promise<void>;
  onRefresh: () => Promise<void>;
}): JSX.Element {
  return (
    <div className="card">
      <h3>
        历史 <span className="dim">({p.runs.length})</span>
        <button
          className="reset"
          style={{ marginLeft: 'auto', float: 'right' }}
          onClick={() => p.onRefresh()}
        >
          refresh
        </button>
      </h3>
      {p.runs.length === 0 && <div className="dim">还没有历史 run</div>}
      <div className="runs-list">
        {p.runs.map((r) => (
          <button key={r.id} className="run-item" onClick={() => p.onLoad(r.id)} title={r.id}>
            <div className="run-item-line1">
              <span className="run-item-title">{r.title || <span className="dim">(no title)</span>}</span>
              <span className={`run-item-reason reason-${r.reason}`}>{r.reason}</span>
            </div>
            <div className="run-item-line2">
              <span className="dim">{r.ts.replace('T', ' ').slice(0, 19)}</span>
              <span className="dim">·</span>
              <span className="dim">{r.model.split('/').pop()}</span>
              <span className="dim">·</span>
              <span className="dim">{r.turns}t</span>
              <span className="dim">·</span>
              <span className="dim">{r.totalTokens.toLocaleString()} tok</span>
            </div>
          </button>
        ))}
      </div>
    </div>
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
  status: RunStatus;
  onContinue: (additionalTurns: number) => Promise<void> | void;
}): JSX.Element {
  const canContinue =
    p.status === 'done' &&
    p.result &&
    !!p.result.runId &&
    (p.result.reason === 'turn_cap' || p.result.reason === 'wall_cap');
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
        {p.turns.map((t, i) => (
          <Turn key={`${t.turn}-${i}`} t={t} />
        ))}
      </div>

      {canContinue && (
        <div className="continue-bar">
          <span className="dim">达到上限 — 手动继续：</span>
          <button onClick={() => p.onContinue(1)}>+1 turn</button>
          <button onClick={() => p.onContinue(3)}>+3</button>
          <button onClick={() => p.onContinue(5)}>+5</button>
        </div>
      )}

      {p.result && <ResultBlock r={p.result} />}
    </div>
  );
}

function TokenTable({ turns }: { turns: TurnEvent[] }): JSX.Element {
  const last = turns.length ? turns[turns.length - 1] : null;
  const mainCum = last?.cumulativeUsage;
  const collabCum = last?.cumulativeCollaboratorUsage;
  return (
    <table className="tokens">
      <thead>
        <tr>
          <th>turn</th>
          <th>phase</th>
          <th>Δ in</th>
          <th>Δ out</th>
          <th>Δ cached</th>
          <th>collab Δ</th>
          <th>cum in</th>
          <th>cum out</th>
        </tr>
      </thead>
      <tbody>
        {turns.map((t) => {
          const c = t.collaboratorTurnUsage;
          return (
            <tr key={t.turn}>
              <td>{t.turn}</td>
              <td>{t.progress.phase}</td>
              <td className="num">{t.turnUsage.input.toLocaleString()}</td>
              <td className="num">{t.turnUsage.output.toLocaleString()}</td>
              <td className="num dim">{(t.turnUsage.cached ?? 0).toLocaleString()}</td>
              <td className="num dim">{c ? `${c.input}/${c.output}` : '—'}</td>
              <td className="num dim">{t.cumulativeUsage.input.toLocaleString()}</td>
              <td className="num dim">{t.cumulativeUsage.output.toLocaleString()}</td>
            </tr>
          );
        })}
        {mainCum && (
          <tr className="total">
            <td colSpan={2}>主模型 total</td>
            <td className="num">{mainCum.input.toLocaleString()}</td>
            <td className="num">{mainCum.output.toLocaleString()}</td>
            <td className="num dim">{(mainCum.cached ?? 0).toLocaleString()}</td>
            <td colSpan={3} />
          </tr>
        )}
        {collabCum && collabCum.total > 0 && (
          <tr className="total">
            <td colSpan={2}>协作者 total</td>
            <td className="num">{collabCum.input.toLocaleString()}</td>
            <td className="num">{collabCum.output.toLocaleString()}</td>
            <td className="num dim">{(collabCum.cached ?? 0).toLocaleString()}</td>
            <td colSpan={3} />
          </tr>
        )}
      </tbody>
    </table>
  );
}

function Turn({ t }: { t: TurnEvent }): JSX.Element {
  // Build id → tool name map so we can decide whether to collapse the
  // matching tool_result by default (web_search and fetch_url are
  // typically huge / noisy; propose_plan / take_note / decline are
  // small and worth seeing inline).
  const toolName = new Map<string, string>();
  for (const m of t.newMessages) {
    if (m.role === 'assistant' && m.tool_calls) {
      for (const tc of m.tool_calls) toolName.set(tc.id, tc.function.name);
    }
  }
  const NOISY = new Set(['web_search', 'fetch_url']);

  return (
    <details className="turn" open>
      <summary>
        turn {t.turn} <span className="dim">phase={t.progress.phase} · in={t.turnUsage.input.toLocaleString()} out={t.turnUsage.output.toLocaleString()}</span>
      </summary>
      {t.newMessages.map((m, i) => {
        if (m.role === 'assistant') {
          return (
            <div key={i} className="m-asst">
              {m.reasoning_content && (
                <details className="asst-thinking">
                  <summary>
                    🧠 thinking <span className="dim">({m.reasoning_content.length.toLocaleString()} chars)</span>
                  </summary>
                  <pre>{m.reasoning_content}</pre>
                </details>
              )}
              {m.content && <div className="asst-text">{m.content}</div>}
              {m.tool_calls?.map((tc) => {
                const noisy = NOISY.has(tc.function.name);
                return (
                  <details key={tc.id} className="tool-call" open={!noisy}>
                    <summary>
                      <span className="tc-name">tool_call {tc.function.name}</span>
                      {noisy && <span className="dim"> · (折叠) {firstArgPreview(tc.function.arguments)}</span>}
                    </summary>
                    <pre>{tc.function.arguments}</pre>
                  </details>
                );
              })}
            </div>
          );
        }
        const name = toolName.get(m.tool_call_id) ?? '';
        const noisy = NOISY.has(name);
        return (
          <details key={i} className="m-tool" open={!noisy}>
            <summary>
              <span className="tc-name">tool_result {name && <span className="dim">· {name}</span>}</span>
              {noisy && <span className="dim"> · {(m.content ?? '').length.toLocaleString()} chars</span>}
            </summary>
            <pre>{m.content}</pre>
          </details>
        );
      })}
    </details>
  );
}

// Pull the first short value out of the tool-call JSON args for an
// inline preview when it's collapsed.
function firstArgPreview(args: string): string {
  try {
    const o = JSON.parse(args) as Record<string, unknown>;
    const v = o.query ?? o.url ?? Object.values(o)[0] ?? '';
    return typeof v === 'string' ? v.slice(0, 60) : '';
  } catch {
    return args.slice(0, 60);
  }
}

function ResultBlock({ r }: { r: ResultEvent }): JSX.Element {
  const declined = r.reason === 'declined';
  const empty = !r.finalArticle.trim();
  const writeIn = r.writeUsage?.input ?? 0;
  const writeOut = r.writeUsage?.output ?? 0;
  const phase1In = r.usage.input - writeIn;
  const phase1Out = r.usage.output - writeOut;
  return (
    <div className="result">
      <h3>结果</h3>
      <div className="result-meta">
        reason: <code className={`reason-${r.reason}`}>{r.reason}</code> · turns: {r.turns} ·
        elapsed: {(r.elapsedMs / 1000).toFixed(1)}s ·
        notes: {r.progress.notes.length} · urls: {r.progress.visited_urls.length} · plan rounds: {r.progress.plan_rounds}
      </div>
      {r.writeUsage && (
        <div className="result-meta dim">
          phase 1: in={phase1In.toLocaleString()} out={phase1Out.toLocaleString()} ·
          {' '}phase 2 (write): in={writeIn.toLocaleString()} out={writeOut.toLocaleString()}
        </div>
      )}
      {r.phase1Summary && (
        <details className="phase1-block">
          <summary>phase 1 思考与研究输出 <span className="dim">(被 phase 2 替换)</span></summary>
          <pre>{r.phase1Summary}</pre>
        </details>
      )}

      {declined && (
        <div className="decline-box">
          <strong>机器人选择不写。理由：</strong>
          <div>{r.declineReason || '(没填理由)'}</div>
        </div>
      )}

      {!declined && empty && (
        <div className="silent-box">
          <strong>空奏折。</strong>{' '}
          <span className="dim">
            {r.reason === 'final'
              ? '模型停止调用工具但没产出文章正文 (生产环境下会被删除)。'
              : `模型在 reason=${r.reason} 时退出，未产出正文。`}
          </span>
          {r.lastAssistantText && (
            <details open>
              <summary>模型最后说的话</summary>
              <pre>{r.lastAssistantText}</pre>
            </details>
          )}
        </div>
      )}

      {!empty && r.title && <div>标题: <strong>{r.title}</strong></div>}
      {!empty && r.summary && <div>摘要: <em>{r.summary}</em></div>}
      {!empty && <pre className="article">{r.finalArticle}</pre>}
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
