#!/usr/bin/env node
/**
 * 孤儿界面检测的自测 —— 两个方向都考。
 *
 * 只考"能抓到坏的"等于没验它会不会冤枉好人,所以这里每一组都是成对的:
 *   ① 合成样本:自己造的假仓库,坏样本必须被抓到、好样本必须放过。
 *      为什么要合成的:在真仓库上"看着对"不是证据 —— 判据可能是碰巧对的。
 *   ② 真仓库回归:三个曾经被朴素判据冤枉过的真实类型,必须不再被冤枉;
 *      `GroupWalletView`(作者出的考题)必须被抓到。
 *
 * 跑:node scripts/test-check-orphan-views.mjs
 */
import { analyse } from './check-orphan-views.mjs';

let failures = 0;
function check(label, ok, detail = '') {
  if (ok) {
    console.log(`  ✓ ${label}`);
  } else {
    failures++;
    console.log(`  ✗ ${label}${detail ? `  —— ${detail}` : ''}`);
  }
}

function runOn(files) {
  const sourceFiles = Object.keys(files);
  return analyse({ sourceFiles, testFiles: [], readFile: (f) => files[f] });
}

// ── ① 合成样本 ────────────────────────────────────────────────────────────

console.log('合成样本(自己造的假仓库):');

const FIXTURE = {
  'Sources/App.swift': `
    import SwiftUI
    @main
    struct FixtureApp: App {
      var body: some Scene { WindowGroup { HomeView() } }
    }
  `,
  // 好样本 A:正常的一条链 App → Home → Card
  'Sources/Home.swift': `
    struct HomeView: View {
      var body: some View {
        CardView()
          .fixtureHighlight()
        ProviderHost().makeThing()
        LiveHost()
      }
      // 这行注释提到了 LostView,但注释不算引用
      // LostView LostView LostView
    }
  `,
  'Sources/Card.swift': `
    struct CardView: View { var body: some View { Text("hi") } }
  `,
  // 好样本 B:modifier 只能通过同文件的 extension helper 到达
  'Sources/Highlight.swift': `
    private struct FixtureHighlight: ViewModifier {
      func body(content: Content) -> some View { content }
    }
    extension View {
      func fixtureHighlight() -> some View { modifier(FixtureHighlight()) }
    }
  `,
  // 好样本 C:界面被同文件里的「非 View 类型」构造
  'Sources/Provider.swift': `
    struct ProviderHost {
      func makeThing() -> some View { ProvidedView() }
    }
    private struct ProvidedView: View { var body: some View { Text("x") } }
  `,
  // 坏样本 A:谁都没引用
  'Sources/Lost.swift': `
    struct LostView: View { var body: some View { Text("nobody opens me") } }
  `,
  // 坏样本 B:只有 #Preview 在用 —— 用户到不了
  'Sources/PreviewOnly.swift': `
    struct PreviewOnlyView: View { var body: some View { Text("preview") } }
  `,
  'Sources/SomePreview.swift': `
    struct LiveHost: View { var body: some View { CardView() } }
    #Preview { PreviewOnlyView() }
  `,
  // 坏样本 C:整簇互相引用,但整簇没有入口
  'Sources/ClusterA.swift': `
    struct ClusterAView: View { var body: some View { ClusterBView() } }
  `,
  'Sources/ClusterB.swift': `
    struct ClusterBView: View { var body: some View { ClusterAView() } }
  `,
};

const fx = runOn(FIXTURE);
const fxOrphans = new Set(fx.reachOrphans);

check('入口找得到', [...fx.roots].includes('FixtureApp'), `roots=${[...fx.roots]}`);
// 坏样本必须被抓到
check('抓到:零引用的 LostView', fxOrphans.has('LostView'));
check('抓到:只被注释提到的不算被引用', fxOrphans.has('LostView'));
check('抓到:只被 #Preview 用的 PreviewOnlyView', fxOrphans.has('PreviewOnlyView'));
check('抓到:互相引用但没有入口的整簇(A)', fxOrphans.has('ClusterAView'));
check('抓到:互相引用但没有入口的整簇(B)', fxOrphans.has('ClusterBView'));
// 好样本必须放过
check('放过:正常链上的 HomeView', !fxOrphans.has('HomeView'));
check('放过:正常链上的 CardView', !fxOrphans.has('CardView'));
check('放过:只能经 extension helper 到达的 modifier', !fxOrphans.has('FixtureHighlight'));
check('放过:被同文件非 View 类型构造的 ProvidedView', !fxOrphans.has('ProvidedView'));

// ── ② 真仓库回归 ──────────────────────────────────────────────────────────

console.log('');
console.log('真仓库回归:');

const real = analyse();
const realOrphans = new Set(real.reachOrphans);
const realRefOrphans = new Set(real.refOrphans);

// 作者出的考题:抓不到它,这道闸就没有意义。
check('抓到考题 GroupWalletView', realOrphans.has('GroupWalletView'));

// 这三个是朴素判据(只看"声明文件之外有没有人写它的名字")冤枉过的真实类型。
// 它们必须同时满足:被朴素判据点名 + 不被可达性判据点名 —— 否则这三条回归
// 就退化成了"反正它俩都没报"的空断言。
for (const name of ['BubbleTextSelection', 'SelectableText', 'MathBlockImage', 'MacWelcomeView']) {
  check(
    `不冤枉 ${name}(朴素判据会误报,可达性不该误报)`,
    realRefOrphans.has(name) && !realOrphans.has(name),
    `ref=${realRefOrphans.has(name)} reach=${realOrphans.has(name)}`,
  );
}

// 明摆着在用的界面,一个都不许上榜。
const LIVE = [
  'WelcomeView', 'ConversationView', 'MessageTabView', 'TabRoot', 'WideRootView',
  'ChatActionSheet', 'BubbleView', 'MeTabView', 'EmptyHint', 'EmptyDetailHint',
  'CrewTabView', 'GroupSettingsView', 'SettingsRootView', 'ComposerView',
];
const wronglyFlagged = LIVE.filter((n) => realOrphans.has(n));
check(`不冤枉 ${LIVE.length} 个明摆着在用的界面`, wronglyFlagged.length === 0, wronglyFlagged.join(', '));

// 判据太粗会一上来红几十条 —— 那种清单没人会去处理,等于没做。
check(
  `孤儿数量在可处理范围内(${real.reachOrphans.length} 个,上限 25)`,
  real.reachOrphans.length <= 25,
  '超过就说明判据又变粗了,先调判据再谈接 CI',
);

console.log('');
if (failures > 0) {
  console.log(`${failures} 条不过`);
  process.exit(1);
}
console.log('全过');
