#!/usr/bin/env node
/**
 * 孤儿界面检测 —— 找出「存在但没有任何地方能到达」的 SwiftUI 界面。
 *
 * 由来:`GroupWalletView` 2026-06-03 做好、6-04 挂上入口、6-15 在一次「删 crew
 * 死代码」的清理里被连带摘掉入口,此后三个月全仓零引用 —— 编译过、测试绿、
 * CI 全绿,没有任何机制会响。作者是靠"我记得有过这个东西"才把它翻出来的。
 * 这道检查就是把那个"没人在看的地方"接上一只眼睛。
 *
 * 两个判据,一起报,不互相替代:
 *   • REF  —— 声明文件之外零引用。最保守,几乎不会冤枉人。
 *   • REACH —— 从 @main 的 App/Scene 出发做可达性,到不了就算孤儿。能抓到
 *     「一整簇互相引用、但整簇没有入口」的情况(机组那一簇就是),代价是更
 *     容易误报(反射 / 只在别的 target 里用 / 通过协议存在类型间接构造)。
 *
 * 扫描前会把注释和字符串字面量抹掉 —— 这不是洁癖:`WideRootView` 里有两行
 * 注释提到机组那一簇的类型名,不抹掉的话它们会被当成"还有人在用"。
 * `#Preview` / `PreviewProvider` 的块也会抹掉:只有预览在用 = 用户到不了。
 *
 * 用法:
 *   node scripts/check-orphan-views.mjs                    # 人看的报告(含与基线的对比)
 *   node scripts/check-orphan-views.mjs --json             # 机器读的
 *   node scripts/check-orphan-views.mjs --ref <提交>       # 按历史提交扫,查"哪一笔造出了这个孤儿"
 *   node scripts/check-orphan-views.mjs --update-baseline  # 人认过账之后重新落基线
 *   node scripts/check-orphan-views.mjs --gate             # 有未豁免孤儿则 exit 1(暂未接 CI)
 *
 * 在 CI 里跑到 `GITHUB_STEP_SUMMARY` 时会额外写一份 markdown 摘要 —— 非阻塞
 * 不等于没人看,而且打的是「本次 N / 基线 M」的对比:只打当前数字,没人会
 * 注意到它哪天从 11 变成 12,**而多出一个孤儿才是信号,比总数重要**。
 *
 * 豁免走 scripts/orphan-view-allowlist.tsv,每条必须带理由和回看日期 ——
 * 不带理由的豁免两个月后就没人知道它为什么在那儿。基线走
 * scripts/orphan-view-baseline.json,只能由人显式更新。
 *
 * ⚠️ 觉得这道检查烦、想摘掉它之前,先读 docs/decisions.md 的 **D6** ——
 * 那里有它为什么存在(五个孤儿的回溯数字)、以及改它/摘它的合法路径。
 * 那一条最后留了个问题:**下一次有人删掉某个界面的最后一个入口时,谁会知道?**
 * 答得上来再摘。
 */
import { execFileSync } from 'node:child_process';
import { appendFileSync, existsSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const root = process.cwd();
const SOURCE_ROOTS = ['apps/pendingbot/Sources'];
const TEST_ROOTS = ['apps/pendingbot/Tests'];
const ALLOWLIST = 'scripts/orphan-view-allowlist.tsv';
const BASELINE = 'scripts/orphan-view-baseline.json';

/** 算作「界面」的一致性协议。ViewModifier / Representable 也是用户看得见的东西。 */
const VIEW_PROTOCOLS = new Set([
  'View',
  'ViewModifier',
  'Scene',
  'App',
  'UIViewRepresentable',
  'UIViewControllerRepresentable',
  'NSViewRepresentable',
  'NSViewControllerRepresentable',
]);

// ── 取文件 ────────────────────────────────────────────────────────────────

function gitFiles(ref) {
  const argv = ref ? ['ls-tree', '-r', '--name-only', ref] : ['ls-files'];
  return execFileSync('git', argv, { cwd: root, encoding: 'utf8', maxBuffer: 64 << 20 })
    .split('\n')
    .filter(Boolean);
}

function swiftFilesUnder(prefixes, ref) {
  return gitFiles(ref).filter(
    (f) => f.endsWith('.swift') && prefixes.some((p) => f.startsWith(p + '/')),
  );
}

/**
 * 按历史提交读文件 —— 用来回答「这个孤儿是哪一笔提交造出来的」。
 * 走 `git show <ref>:<path>`,不碰工作区、不 checkout(别的 worktree 里可能
 * 躺着没提交的手改)。
 */
function readAtRef(ref, file) {
  return execFileSync('git', ['show', `${ref}:${file}`], {
    cwd: root,
    encoding: 'utf8',
    maxBuffer: 64 << 20,
  });
}

// ── 抹掉注释 / 字符串 / 预览块 ─────────────────────────────────────────────

/**
 * 把注释和字符串字面量替换成等长空格(保留换行,行号不漂)。
 * Swift 的块注释可以嵌套,这里按嵌套处理。
 */
function stripCommentsAndStrings(src) {
  const out = Array.from(src);
  const n = src.length;
  let i = 0;
  const blank = (from, to) => {
    for (let k = from; k < to && k < n; k++) if (out[k] !== '\n') out[k] = ' ';
  };

  while (i < n) {
    const c = src[i];
    const d = src[i + 1];

    if (c === '/' && d === '/') {
      let j = i;
      while (j < n && src[j] !== '\n') j++;
      blank(i, j);
      i = j;
      continue;
    }
    if (c === '/' && d === '*') {
      let depth = 1;
      let j = i + 2;
      while (j < n && depth > 0) {
        if (src[j] === '/' && src[j + 1] === '*') { depth++; j += 2; continue; }
        if (src[j] === '*' && src[j + 1] === '/') { depth--; j += 2; continue; }
        j++;
      }
      blank(i, j);
      i = j;
      continue;
    }
    if (c === '"' && d === '"' && src[i + 2] === '"') {
      const end = src.indexOf('"""', i + 3);
      const j = end === -1 ? n : end + 3;
      blank(i, j);
      i = j;
      continue;
    }
    if (c === '"') {
      let j = i + 1;
      while (j < n) {
        if (src[j] === '\\') { j += 2; continue; }
        if (src[j] === '"' || src[j] === '\n') { j++; break; }
        j++;
      }
      blank(i, j);
      i = j;
      continue;
    }
    i++;
  }
  return out.join('');
}

/** 从 `openIdx`(必须落在 `{` 上或其前)出发做花括号配对,返回闭合括号的下标+1。 */
function matchBrace(src, openIdx) {
  let i = src.indexOf('{', openIdx);
  if (i === -1) return -1;
  let depth = 0;
  for (; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}') {
      depth--;
      if (depth === 0) return i + 1;
    }
  }
  return -1;
}

/** 抹掉 `#Preview {...}` 与 `struct X_Previews: PreviewProvider {...}` 的整块。 */
function stripPreviews(src) {
  let text = src;
  const patterns = [
    /#Preview\b[^{]*\{/g,
    /\bstruct\s+\w+\s*:\s*PreviewProvider\s*\{/g,
  ];
  for (const re of patterns) {
    let guard = 0;
    for (;;) {
      re.lastIndex = 0;
      const m = re.exec(text);
      if (!m || guard++ > 500) break;
      const end = matchBrace(text, m.index);
      if (end === -1) break;
      text =
        text.slice(0, m.index) +
        text.slice(m.index, end).replace(/[^\n]/g, ' ') +
        text.slice(end);
    }
  }
  return text;
}

// ── 找声明 ────────────────────────────────────────────────────────────────

/**
 * 声明形如:
 *   struct Foo: View {
 *   private struct Bar<T>: View, Equatable {
 *   struct Baz: SomeProtocol,
 *              View {
 * 一致性列表可能跨行,所以先抓到 `{` 之前的全部内容再拆。
 */
function findViewDeclarations(text) {
  const re = /\b(?:public\s+|internal\s+|fileprivate\s+|private\s+)?struct\s+([A-Z]\w*)\s*(<[^>]*>)?\s*:\s*([^{]+)\{/g;
  const found = [];
  let m;
  while ((m = re.exec(text)) !== null) {
    const name = m[1];
    const conformances = m[3]
      .split(/[,\s]+/)
      .map((s) => s.replace(/<.*/, '').trim())
      .filter(Boolean);
    if (conformances.includes('PreviewProvider')) continue;
    if (conformances.some((c) => VIEW_PROTOCOLS.has(c))) {
      found.push({ name, conformances, index: m.index });
    }
  }
  return found;
}

/** `@main` 标注的类型 = 应用入口,可达性从这里起步。 */
function findMainEntries(text) {
  const re = /@main\s+(?:public\s+|internal\s+)?struct\s+([A-Z]\w*)/g;
  const out = [];
  let m;
  while ((m = re.exec(text)) !== null) out.push(m[1]);
  return out;
}

/**
 * 所有顶层具名类型 —— **不只是 View**。
 *
 * 为什么要收非 View 的:`MathBlockImage` 是被 `MathBlockImageProvider`
 * (一个 `ImageProvider`,不是 View)构造出来的。只连 View→View 的图会认为
 * 它没人用,而它其实活得好好的。
 */
function findAllTypeDeclarations(text) {
  const re = /\b(?:public\s+|internal\s+|fileprivate\s+|private\s+|final\s+)*(?:struct|class|enum|actor|protocol)\s+([A-Z]\w*)/g;
  const out = [];
  let m;
  while ((m = re.exec(text)) !== null) out.push(m[1]);
  return out;
}

/**
 * `extension` 里声明的成员名(func / var)。
 *
 * 为什么要收:`BubbleTextSelection` 这个 ViewModifier 谁都没直接写过它的
 * 名字 —— 调用方写的是 `.bubbleTextSelection(id:)`,那个 helper 和 modifier
 * 在同一个文件里。不认 `.foo()` 这条边,这类 modifier 会被整片冤枉成孤儿。
 */
function findExtensionMembers(text) {
  const members = [];
  const re = /\bextension\s+[A-Z]\w*(?:<[^>]*>)?[^{]*\{/g;
  let m;
  while ((m = re.exec(text)) !== null) {
    const end = matchBrace(text, m.index);
    if (end === -1) continue;
    const body = text.slice(m.index, end);
    const memberRe = /\b(?:func|var)\s+([a-z]\w*)/g;
    let mm;
    while ((mm = memberRe.exec(body)) !== null) members.push(mm[1]);
  }
  return members;
}

// ── 豁免清单 ──────────────────────────────────────────────────────────────

function readAllowlist() {
  const abs = path.join(root, ALLOWLIST);
  const entries = new Map();
  const problems = [];
  if (!existsSync(abs)) return { entries, problems };
  const lines = readFileSync(abs, 'utf8').split('\n');
  lines.forEach((raw, idx) => {
    const line = raw.trim();
    if (!line || line.startsWith('#')) return;
    const [symbol, reason, revisit] = raw.split('\t');
    const lineNo = idx + 1;
    if (!symbol?.trim()) return;
    if (!reason?.trim()) {
      problems.push(`${ALLOWLIST}:${lineNo} 「${symbol.trim()}」没写理由 —— 不带理由的豁免不收`);
      return;
    }
    if (!revisit?.trim()) {
      problems.push(`${ALLOWLIST}:${lineNo} 「${symbol.trim()}」没写回看日期 —— 豁免必须有期限`);
      return;
    }
    entries.set(symbol.trim(), { reason: reason.trim(), revisit: revisit.trim(), lineNo });
  });
  return { entries, problems };
}

// ── 基线对比 ──────────────────────────────────────────────────────────────

/**
 * 基线 = 上一次有人认过账的那份孤儿名单。
 *
 * 为什么必须有它:只打一个"本次 11 个",没人会注意到它哪天变成了 12。
 * **多出来一个孤儿这件事本身就是信号,比总数重要** —— 那正是 2026-06-09
 * 那天发生却没人发现的事。
 *
 * 基线只能由人显式更新(`--update-baseline` + 一笔提交),不会自动跟着涨 ——
 * 自动跟涨的基线等于没有基线。
 */
function readBaseline() {
  const abs = path.join(root, BASELINE);
  if (!existsSync(abs)) return null;
  try {
    return JSON.parse(readFileSync(abs, 'utf8'));
  } catch {
    return null;
  }
}

export function diffAgainstBaseline(current, baseline) {
  // 没有基线时不能把「当前全部」当成「本次新增」—— 那会让第一次运行看起来
  // 像是一天之内冒出 11 个孤儿,而真相是还没有人认过账。
  if (!baseline) return { added: [], gone: [], baselineCount: null, baselineRef: null };
  const before = new Set(baseline.reachOrphans ?? []);
  const now = new Set(current);
  return {
    added: [...now].filter((n) => !before.has(n)),
    gone: [...before].filter((n) => !now.has(n)),
    baselineCount: before.size,
    baselineRef: baseline.measuredAt ?? null,
  };
}

// ── 主流程 ────────────────────────────────────────────────────────────────

/**
 * @param input 省略即扫真仓库。测试传合成文件表进来 —— 判据得能拿假样本考,
 *              不然只能靠"在真仓库上看着对"来自证,那不是证据。
 */
export function analyse(input) {
  const ref = input?.ref;
  const sourceFiles = input?.sourceFiles ?? swiftFilesUnder(SOURCE_ROOTS, ref);
  const testFiles = input?.testFiles ?? swiftFilesUnder(TEST_ROOTS, ref);
  const readOne =
    input?.readFile ??
    (ref ? (f) => readAtRef(ref, f) : (f) => readFileSync(path.join(root, f), 'utf8'));

  /** file -> 抹干净的文本 */
  const clean = new Map();
  for (const f of [...sourceFiles, ...testFiles]) {
    clean.set(f, stripPreviews(stripCommentsAndStrings(readOne(f))));
  }

  /** 声明表:name -> { file, conformances } */
  const decls = new Map();
  const roots = new Set();
  for (const f of sourceFiles) {
    const text = clean.get(f);
    for (const d of findViewDeclarations(text)) {
      // 同名重复声明(不同 target / 私有同名)只记第一处,并标记出来。
      if (decls.has(d.name)) {
        decls.get(d.name).duplicateIn.push(f);
        continue;
      }
      decls.set(d.name, { name: d.name, file: f, conformances: d.conformances, duplicateIn: [] });
    }
    for (const r of findMainEntries(text)) roots.add(r);
  }

  /** name -> Set(引用它的文件),不含声明文件自身 */
  const refs = new Map();
  const testRefs = new Map();
  for (const name of decls.keys()) {
    refs.set(name, new Set());
    testRefs.set(name, new Set());
  }
  const nameList = [...decls.keys()];
  // 一次扫一个文件、对所有名字建索引,比 N×M 次正则快得多。
  const wordRe = /\b[A-Z]\w*\b/g;
  const declared = new Set(nameList);
  for (const f of [...sourceFiles, ...testFiles]) {
    const text = clean.get(f);
    const isTest = testFiles.includes(f);
    const seen = new Set();
    let m;
    wordRe.lastIndex = 0;
    while ((m = wordRe.exec(text)) !== null) {
      if (declared.has(m[0])) seen.add(m[0]);
    }
    for (const name of seen) {
      if (decls.get(name).file === f) continue; // 自己文件里的不算
      (isTest ? testRefs : refs).get(name).add(f);
    }
  }

  // ── 判据 A:声明文件之外零引用 ──
  const refOrphans = nameList.filter((n) => refs.get(n).size === 0 && !roots.has(n));

  // ── 判据 B:从 @main 出发的可达性 ──
  //
  // 节点是「文件」而不是「类型」,理由是踩出来的:一个界面可以被同文件里的
  // 非 View 类型构造(MathBlockImage ← MathBlockImageProvider),也可以只被
  // 同文件里的 `extension View` helper 构造(BubbleTextSelection ←
  // `.bubbleTextSelection(id:)`)。只连 View→View 会把这两类整片冤枉掉。
  // 文件粒度换来的代价是:同一个文件里死掉的那一个界面,只要文件本身还活着
  // 就抓不到 —— 这是明知的取舍,写在报告里。
  const allTypes = new Map();       // 类型名 -> 声明它的文件
  const extMembers = new Map();     // extension 成员名 -> 声明它的文件集合
  for (const f of sourceFiles) {
    const text = clean.get(f);
    for (const t of findAllTypeDeclarations(text)) if (!allTypes.has(t)) allTypes.set(t, f);
    for (const mem of findExtensionMembers(text)) {
      if (!extMembers.has(mem)) extMembers.set(mem, new Set());
      extMembers.get(mem).add(f);
    }
  }

  const fileEdges = new Map(sourceFiles.map((f) => [f, new Set()]));
  const memberCallRe = /\.([a-z]\w*)\s*\(/g;
  for (const f of sourceFiles) {
    const text = clean.get(f);
    let m;
    wordRe.lastIndex = 0;
    while ((m = wordRe.exec(text)) !== null) {
      const target = allTypes.get(m[0]);
      if (target && target !== f) fileEdges.get(f).add(target);
    }
    memberCallRe.lastIndex = 0;
    while ((m = memberCallRe.exec(text)) !== null) {
      for (const target of extMembers.get(m[1]) ?? []) {
        if (target !== f) fileEdges.get(f).add(target);
      }
    }
  }

  const rootFiles = new Set();
  for (const r of roots) if (allTypes.has(r)) rootFiles.add(allTypes.get(r));
  const reachableFiles = new Set();
  const queue = [...rootFiles];
  while (queue.length) {
    const cur = queue.pop();
    if (reachableFiles.has(cur)) continue;
    reachableFiles.add(cur);
    for (const next of fileEdges.get(cur) ?? []) if (!reachableFiles.has(next)) queue.push(next);
  }
  const reachable = new Set(nameList.filter((n) => reachableFiles.has(decls.get(n).file)));
  const reachOrphans = nameList.filter((n) => !reachable.has(n));

  return { decls, roots, refs, testRefs, refOrphans, reachOrphans, sourceFiles, testFiles };
}

// ── 输出 ──────────────────────────────────────────────────────────────────

// 只有被当成命令行程序直接跑时才产出报告 —— 被 import 时(自测)不做任何事。
const invokedDirectly =
  process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;

if (invokedDirectly) main();

function main() {
  const argv = process.argv.slice(2);
  const args = new Set(argv);
  const refArg = argv.includes('--ref') ? argv[argv.indexOf('--ref') + 1] : null;

  const result = analyse(refArg ? { ref: refArg } : undefined);
  const { entries: allow, problems: allowProblems } = readAllowlist();
  const reachOrphans = result.reachOrphans;
  const unexcused = reachOrphans.filter((n) => !allow.has(n));
  const diff = diffAgainstBaseline(reachOrphans, readBaseline());

  if (args.has('--update-baseline')) {
    const head = execFileSync('git', ['rev-parse', '--short', 'HEAD'], {
      cwd: root,
      encoding: 'utf8',
    }).trim();
    writeFileSync(
      path.join(root, BASELINE),
      JSON.stringify(
        {
          _: '孤儿界面基线 —— 由 `node scripts/check-orphan-views.mjs --update-baseline` 生成。只在人认过账之后更新,别让它自动跟着涨。',
          measuredAt: refArg ?? head,
          count: reachOrphans.length,
          reachOrphans,
        },
        null,
        2,
      ) + '\n',
    );
    console.log(`基线已写入 ${BASELINE}:${reachOrphans.length} 个(测于 ${refArg ?? head})`);
    return;
  }

  if (args.has('--json')) {
    console.log(
      JSON.stringify(
        {
          measuredAt: refArg ?? 'worktree',
          declared: result.decls.size,
          roots: [...result.roots],
          refOrphans: result.refOrphans.map((n) => ({
            name: n,
            file: result.decls.get(n).file,
            testOnlyRefs: [...result.testRefs.get(n)],
            excused: allow.has(n),
          })),
          reachOrphans: reachOrphans.map((n) => ({ name: n, file: result.decls.get(n).file })),
          diff,
          allowlistProblems: allowProblems,
        },
        null,
        2,
      ),
    );
  } else {
    const pad = (s) => String(s).padStart(3, ' ');
    console.log(`扫描对象: ${refArg ?? '工作区'}`);
    console.log(`扫描: ${result.sourceFiles.length} 个源文件 + ${result.testFiles.length} 个测试文件`);
    console.log(`界面声明: ${result.decls.size} 个   入口(@main): ${[...result.roots].join(', ') || '(无)'}`);
    console.log('');
    console.log(`[REF]   声明文件之外零引用: ${pad(result.refOrphans.length)} 个(本仓库这个判据太粗,只作参考)`);
    console.log('');
    console.log(`[REACH] 从 @main 到不了: ${pad(reachOrphans.length)} 个`);
    for (const name of reachOrphans) {
      const isNew = diff.added.includes(name) ? '  ⚠️ 新增' : '';
      const mark = allow.has(name) ? ' (已豁免)' : '';
      console.log(`        ${name}  ${result.decls.get(name).file}${mark}${isNew}`);
    }
    console.log('');
    console.log(renderComparison(diff, reachOrphans.length));
    if (allowProblems.length) {
      console.log('');
      console.log('豁免清单有问题:');
      for (const p of allowProblems) console.log(`        ${p}`);
    }
  }

  if (process.env.GITHUB_STEP_SUMMARY) {
    appendFileSync(
      process.env.GITHUB_STEP_SUMMARY,
      renderSummaryMarkdown(result, reachOrphans, diff, allow, allowProblems),
    );
  }

  if (args.has('--gate')) {
    if (allowProblems.length) process.exit(1);
    if (unexcused.length) process.exit(1);
  }
}

/** 「本次几个 / 基线几个」这一段 —— 只打当前数字没人会发现它从 11 变成了 12。 */
function renderComparison(diff, count) {
  if (diff.baselineCount === null) {
    return `基线: 还没有(跑 \`node scripts/check-orphan-views.mjs --update-baseline\` 建一份)`;
  }
  const delta = count - diff.baselineCount;
  const arrow = delta === 0 ? '持平' : delta > 0 ? `多了 ${delta} 个` : `少了 ${-delta} 个`;
  const lines = [`对比基线: 本次 ${count} 个 / 基线 ${diff.baselineCount} 个(测于 ${diff.baselineRef}) —— ${arrow}`];
  if (diff.added.length) lines.push(`  ⚠️ 新增孤儿: ${diff.added.join(', ')}  ← 这条比总数重要`);
  if (diff.gone.length) lines.push(`  ✅ 不再是孤儿: ${diff.gone.join(', ')}`);
  if (diff.added.length || diff.gone.length) {
    lines.push('  名单变了就该更新基线(--update-baseline),并在提交信息里说清为什么变。');
  }
  return lines.join('\n');
}

/** CI 的 job summary —— 非阻塞不等于没人看,报告要落在人会看见的地方。 */
function renderSummaryMarkdown(result, reachOrphans, diff, allow, allowProblems) {
  const out = ['## 孤儿界面检测', ''];
  if (diff.baselineCount === null) {
    out.push(`本次 **${reachOrphans.length}** 个;仓库里还没有基线。`);
  } else {
    const delta = reachOrphans.length - diff.baselineCount;
    const arrow = delta === 0 ? '持平' : delta > 0 ? `**多了 ${delta} 个**` : `少了 ${-delta} 个`;
    out.push(`本次 **${reachOrphans.length}** 个 / 基线 **${diff.baselineCount}** 个(测于 \`${diff.baselineRef}\`) —— ${arrow}`);
  }
  out.push('');
  if (diff.added.length) {
    out.push('### ⚠️ 这次多出来的孤儿', '');
    out.push('有界面失去了最后一个入口。**编译和测试都不会因此变红** —— 这一段就是唯一会说话的地方。', '');
    for (const n of diff.added) out.push(`- \`${n}\` — \`${result.decls.get(n).file}\``);
    out.push('');
    out.push('正确处置三选一:**挂回入口** / **删掉** / **写进 `scripts/orphan-view-allowlist.tsv` 并注明理由和复查时间**。');
    out.push('');
  }
  if (diff.gone.length) {
    out.push(`### ✅ 不再是孤儿`, '', diff.gone.map((n) => `- \`${n}\``).join('\n'), '');
  }
  out.push('<details><summary>完整名单</summary>', '');
  for (const n of reachOrphans) {
    out.push(`- \`${n}\` — \`${result.decls.get(n).file}\`${allow.has(n) ? ' (已豁免)' : ''}`);
  }
  out.push('', '</details>', '');
  if (allowProblems.length) {
    out.push('### 豁免清单本身有问题', '', ...allowProblems.map((p) => `- ${p}`), '');
  }
  out.push('_这道检查目前**不拦人**。它存在的理由是:界面失去最后一个入口时,编译过、测试绿、CI 全绿 —— 没有别的地方会响。_');
  return out.join('\n') + '\n';
}
