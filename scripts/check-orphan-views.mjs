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
 *   node scripts/check-orphan-views.mjs            # 人看的报告
 *   node scripts/check-orphan-views.mjs --json     # 机器读的
 *   node scripts/check-orphan-views.mjs --gate     # 有未豁免孤儿则 exit 1
 *
 * 豁免走 scripts/orphan-view-allowlist.tsv,每条必须带理由和回看日期 ——
 * 不带理由的豁免两个月后就没人知道它为什么在那儿。
 */
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const root = process.cwd();
const SOURCE_ROOTS = ['apps/pendingbot/Sources'];
const TEST_ROOTS = ['apps/pendingbot/Tests'];
const ALLOWLIST = 'scripts/orphan-view-allowlist.tsv';

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

function gitFiles() {
  return execFileSync('git', ['ls-files'], { cwd: root, encoding: 'utf8' })
    .split('\n')
    .filter(Boolean);
}

function swiftFilesUnder(prefixes) {
  return gitFiles().filter(
    (f) => f.endsWith('.swift') && prefixes.some((p) => f.startsWith(p + '/')),
  );
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

// ── 主流程 ────────────────────────────────────────────────────────────────

/**
 * @param input 省略即扫真仓库。测试传合成文件表进来 —— 判据得能拿假样本考,
 *              不然只能靠"在真仓库上看着对"来自证,那不是证据。
 */
export function analyse(input) {
  const sourceFiles = input?.sourceFiles ?? swiftFilesUnder(SOURCE_ROOTS);
  const testFiles = input?.testFiles ?? swiftFilesUnder(TEST_ROOTS);
  const readOne = input?.readFile ?? ((f) => readFileSync(path.join(root, f), 'utf8'));

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
const args = new Set(process.argv.slice(2));
const result = analyse();
const { entries: allow, problems: allowProblems } = readAllowlist();

const refOrphansUnexcused = result.refOrphans.filter((n) => !allow.has(n));

if (args.has('--json')) {
  console.log(
    JSON.stringify(
      {
        declared: result.decls.size,
        roots: [...result.roots],
        refOrphans: result.refOrphans.map((n) => ({
          name: n,
          file: result.decls.get(n).file,
          testOnlyRefs: [...result.testRefs.get(n)],
          excused: allow.has(n),
        })),
        reachOrphans: result.reachOrphans.map((n) => ({ name: n, file: result.decls.get(n).file })),
        allowlistProblems: allowProblems,
      },
      null,
      2,
    ),
  );
} else {
  const n = (s) => String(s).padStart(3, ' ');
  console.log(`扫描: ${result.sourceFiles.length} 个源文件 + ${result.testFiles.length} 个测试文件`);
  console.log(`界面声明: ${result.decls.size} 个   入口(@main): ${[...result.roots].join(', ') || '(无)'}`);
  console.log('');
  console.log(`[REF]   声明文件之外零引用: ${n(result.refOrphans.length)} 个`);
  for (const name of result.refOrphans) {
    const t = result.testRefs.get(name).size;
    const mark = allow.has(name) ? ' (已豁免)' : '';
    const testNote = t > 0 ? `  ← 只有测试在用(${t} 处)` : '';
    console.log(`        ${name}  ${result.decls.get(name).file}${testNote}${mark}`);
  }
  console.log('');
  console.log(`[REACH] 从 @main 到不了: ${n(result.reachOrphans.length)} 个`);
  for (const name of result.reachOrphans) {
    const alsoRef = result.refOrphans.includes(name) ? '' : '  (有人引用,但整簇没有入口)';
    console.log(`        ${name}  ${result.decls.get(name).file}${alsoRef}`);
  }
  if (allowProblems.length) {
    console.log('');
    console.log('豁免清单有问题:');
    for (const p of allowProblems) console.log(`        ${p}`);
  }
}

if (args.has('--gate')) {
  if (allowProblems.length) process.exit(1);
  if (refOrphansUnexcused.length) process.exit(1);
}
}
