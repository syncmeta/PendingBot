#!/usr/bin/env bash
#
# 算出这次 TestFlight 发版该用的 CFBundleVersion，核实它不倒退，可选地写进
# project.yml。
#
# 为什么不是 `git rev-list --count HEAD`
# ------------------------------------
# 曾经是。2026-08-11 那版（0.1.0 build 3571）就是这么来的。然后本地仓库丢了、
# 从落后一个月的 origin 重新拉回来，提交数掉到 3178 —— **build 号倒退 393**，
# App Store Connect 会直接拒收，从新仓库一版都发不出去。
#
# 根因不是「数字太小」，是 build 号从 git 历史算，而历史正是会丢的那样东西。
# 所以改成从 UTC 时间派生：天生单调，不依赖仓库状态，从 tarball / 浅克隆 /
# 重建过的仓库构建都对。
#
# 格式合法性（Apple 官方，不是印象）
# ------------------------------------
# - TN2420 <https://developer.apple.com/library/archive/technotes/tn2420/_index.html>:
#   "must consist only of '.'s and numbers and must begin and end with a number
#    ... may have up to three components separated by periods. The total number
#    of characters ... cannot exceed eighteen characters."
# - 现行 CFBundleVersion 文档: "a machine-readable string composed of one to
#   three period-separated integers ... can only contain numeric characters
#   (0-9) and periods."
#
# `202608180940` = 12 字符（限 18）、1 段（限 3）、纯数字、首尾是数字 → 合法。
#
# 已知的、没被文档证明的一条假设
# ------------------------------------
# 12 位单段 ≈ 2.03e11，超 32 位整数。文档只管字符数、不管数值宽度，ASC 内部
# parser 到底多宽只有真上传才知道。失败模式温和：**上传那步就炸，不会有东西
# 到用户手上**。真撞上就切备用格式 BUILD_NUMBER_FORMAT=dotted（见 --help）。
#
# 用法
#   scripts/release/ios-build-number.sh              # 只打印，不改文件
#   scripts/release/ios-build-number.sh --apply      # 顺便写进 project.yml + xcodegen
#   BUILD_NUMBER_FORMAT=dotted scripts/release/ios-build-number.sh
#
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
project_yml="$repo_root/apps/pendingbot/project.yml"
guard="$repo_root/scripts/release/asc_highest_build.py"

apply=0
for arg in "$@"; do
  case "$arg" in
    --apply) apply=1 ;;
    -h|--help)
      sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^#\{1,2\} \{0,1\}//'
      exit 0
      ;;
    *) echo "未知参数: $arg" >&2; exit 2 ;;
  esac
done

# --- 1. 算候选 build 号 -----------------------------------------------------
case "${BUILD_NUMBER_FORMAT:-plain}" in
  plain)
    # 默认。202608180940
    candidate="$(date -u +%Y%m%d%H%M)"
    ;;
  dotted)
    # 备用。20260818.0940 —— 两段，每段都远小于 2^31。只在 plain 被 ASC 拒收
    # （或 Sparkle 那侧需要）时切过来；两边逐段比较，序不变。
    candidate="$(date -u +%Y%m%d).$(date -u +%H%M)"
    ;;
  *)
    echo "BUILD_NUMBER_FORMAT 只认 plain / dotted，收到: $BUILD_NUMBER_FORMAT" >&2
    exit 2
    ;;
esac

# --- 2. 防倒退闸：跟 ASC 上已有的最高 build 号比 ----------------------------
# 取不到就停，不放行。ASC 瞬时故障由 asc_highest_build.py 内部有限重试兜。
highest="$(/usr/bin/python3 "$guard")"

if ! /usr/bin/python3 "$guard" --greater "$candidate" "$highest"; then
  cat >&2 <<EOF
build 号没有严格递增，拒绝发版。
  这次算出来 : $candidate
  ASC 上最高 : $highest
时间戳理论上不该走到这儿。真走到了，说明要么系统时钟不对，要么有人手工传过
一个未来的 build 号 —— 两种都得先弄清楚，不要绕过这道闸。
EOF
  exit 1
fi

echo "$candidate"

# --- 3. 可选：写进 project.yml 并重生 xcodeproj ------------------------------
if [ "$apply" = "1" ]; then
  /usr/bin/sed -i '' -E "s/^( *CURRENT_PROJECT_VERSION: ).*/\1\"$candidate\"/" "$project_yml"
  grep -q "CURRENT_PROJECT_VERSION: \"$candidate\"" "$project_yml" || {
    echo "写 project.yml 失败：没找到 CURRENT_PROJECT_VERSION 行" >&2
    exit 1
  }
  ( cd "$repo_root/apps/pendingbot" && xcodegen )
  echo "已写入 $project_yml 并重生 xcodeproj（ASC 当前最高: $highest）" >&2
fi
