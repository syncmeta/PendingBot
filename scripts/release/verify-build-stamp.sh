#!/bin/sh
# 用法: verify-build-stamp.sh <App.app 路径> <这次该对应的 40 位 commit sha>
#
# 发版侧的硬闸：**分发出去的包必须能被一个 commit 完整复现。**
#
# 打戳本身在构建期做（`scripts/release/stamp-build-info.sh`），那一侧是**宽的** ——
# 外部人从 tarball 编 → 写 `unknown` 照样编得过；开发时工作区脏 → 标 dirty 照样
# 编得过。这里是**严的**那一侧，四种情况一律拒绝出包：
#
#   ① 键不存在      → 打戳这一步压根没跑（build phase 被删了之类）
#   ② 值是 unknown  → 打戳跑了，但构建那台机器上没有 git 信息
#   ③ dirty=true    → 从带未提交改动的工作区打出来的，sha 是骗人的
#   ④ sha 对不上    → 产物不是这次快照打的（拿了旧的 DerivedData 之类）
#
# 为什么两侧政策不同：失败方式不对称。外部人拿到一个标着 `unknown` 的自编包，
# 他知道那是自己编的，无害；而**我们分发出去的 .dmg 要是标着 `unknown` 或
# dirty，那就是一个我们自己也说不出它是哪份代码打的产物** —— 那正好抵消了
# 做这件事的全部意义。
#
# ④ 是这四条里最强的一条：它不只问「有没有戳」，而是问「戳是不是**这次**的」。
set -eu

app=${1:?usage: verify-build-stamp.sh <App.app> <expected-sha>}
want=${2:?usage: verify-build-stamp.sh <App.app> <expected-sha>}
plist="$app/Contents/Info.plist"
test -f "$plist" || { echo "找不到 $plist" >&2; exit 2; }

get() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || true; }

commit=$(get BuildStampCommit)
dirty=$(get BuildStampDirty)

if [ -z "$commit" ]; then
  echo "产物 Info.plist 里没有 BuildStampCommit —— 打戳这一步没跑。" >&2
  echo "  检查 apps/pendingbot/project.yml 的 postBuildScripts 还在不在。" >&2
  echo "  注意：「键不存在」和「键写着 unknown」是两回事，后者说明脚本跑了、" >&2
  echo "  只是那台机器没有 git 信息 —— 别把这两种混为一谈。" >&2
  exit 2
fi

if [ "$commit" = "unknown" ]; then
  echo "产物的 BuildStampCommit 是 unknown —— 构建时拿不到 git 信息。" >&2
  echo "  这在外部人从 tarball 自编时是正常且诚实的，但**我们不能这样分发**：" >&2
  echo "  一个我们自己也说不出它是哪份代码打的包，等于没有 provenance。" >&2
  exit 2
fi

if [ "$dirty" = "true" ]; then
  echo "产物是从**带未提交改动**的工作区打出来的（BuildStampDirty=true）。" >&2
  echo "  它标着 ${commit}，但那个 commit 复现不出这个包。发出去就是谎报。" >&2
  echo "  正常的发版走干净快照，不该出现这种情况 —— 先查为什么快照是脏的。" >&2
  exit 2
fi

if [ "$commit" != "$want" ]; then
  echo "产物的 commit 戳跟这次要发的对不上：" >&2
  echo "  产物里写着 : $commit" >&2
  echo "  这次应该是 : $want" >&2
  echo "  多半是拿到了旧的 DerivedData，或者构建的不是这份快照。" >&2
  exit 2
fi

echo "⑨ 版本戳 ${commit}（干净，且与本次快照一致）"
