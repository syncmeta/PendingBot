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
# 格式：<自 1970-01-01 起的天数>.<当天已过的秒数>
# ------------------------------------
# **这段理由必须留在文件里**，否则以后一定有人嫌 `20683.7160` 看不懂就改掉。
#
# 第一段是**纪元日（epoch day）**，用户定的。可读性是**有意放弃**的 ——
# 这是个机器用的单调标识，不是给人看的日期；要人看的日期在别处（见下面输出
# 的可读时间、以及 TestFlight 的 What to Test）。
#
# 走到这里之前否掉了两个：
#
#   ① YYYYMMDDHHMM（202608180940）—— ≈2.03e11，**超 2^31（2147483647）**。
#      Apple 文档（见下）只约束「≤3 段、≤18 字符、纯数字」，**从不提每段的
#      数值宽度上限**，所以 ASC 内部 parser 吃不吃得下超 2^31 的单段只能靠
#      真上传去赌。不赌。
#
#   ② date -u +%s（1787018157）—— 数值安全（1.79e9），但 **2038-01-19
#      03:14:07 UTC 之后越过 2^31**，同一类风险只是推迟了十二年。
#
# 纪元日两头都躲开：`20683` ≈2.07e4，**小五个数量级**，2^31 要到公元 590 万
# 年才够得着。
#
# 第二段「当天已过的秒数」（0..86399）只为一件事：**同一天要发第二版**。
# 用秒数而不是「今天第几版」是关键 —— 序号需要外部状态（要么人记着填，忘了
# 就撞号；要么每次构建去线上问，把能不能构建绑死在网络上），秒数纯从时钟算，
# 零外部状态，同日天生递增。「发版号依赖外部状态」正是这轮要拆掉的东西。
#
# **第二段固定补零到 5 位（%05d），别去掉**（PendingCrew 机长 4-1 提的）：
# 补零之后「按整数解」和「按字符串解」得出的先后**一致** —— `07160 < 10000`
# 整数成立，字符串比 "0…" < "1…" 也成立。不补零就只剩整数解一条路能对
# （"7160" 字符串比 "700" 反而小）。我们无法确知每个消费方怎么解析这一段，
# 补零让两种解法都不会把同日先后弄反。
#
# 这个格式还有一条不显眼但很硬的好处（4-1 指出）：**它不关门**。纪元日
# 是三个候选里最小的，以后真想改主意，20683 → 20260818（YYYYMMDD）→
# 1787018157（Unix 秒）**逐级都是增**，闸都放行；反过来任何一步都是减，
# 永远切不回去。先上最小的那个，等于把以后改主意的余地留着。
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
# `20683.07160` = 11 字符（限 18）、2 段（限 3）、纯数字、首尾是数字 → 合法。
#
# 用法
#   scripts/release/ios-build-number.sh              # 只打印，不改文件
#   scripts/release/ios-build-number.sh --apply      # 顺便写进 project.yml + xcodegen
#   scripts/release/ios-build-number.sh --check      # 只核 project.yml 里现有的值够不够大
#   scripts/release/ios-build-number.sh --print-only # 只算并打印，跳过 ASC 防倒退闸
#
# --print-only 是给 **macOS Developer ID 直发**（scripts/release/build-macos-dmg.sh）
# 用的，它要的只是「同一套 build 号格式」这一条，不要 ASC 那道闸：
#   - Mac 包不上 App Store Connect，ASC 上根本没有它的账本，拿 iOS 的最高
#     build 去比是比错了对象；
#   - 我们没有 Sparkle / 自更新通道，眼下没有任何消费方按 CFBundleVersion
#     排先后，闸拦不住任何真实事故；
#   - 而它会把「能不能出 Mac 包」绑死在 ASC 可达上 —— 一道拦不住真事故、
#     却会假报警的闸，比没有更糟。
# 单调性由时钟本身保证（见上面的格式论证），不由这道闸保证。
# **哪天 Mac 端真有了更新通道，必须在 build-macos-dmg.sh 里补一道对着那个
# 通道的 fail-closed 闸**（PendingCrew 就是这么做的：比线上 appcast feed 的
# 最大值，且拉不到 feed 就拒绝构建）。已记进 docs/tech-debt.md。
#
# --check 是给「archive 之前」用的断言：写进 project.yml 的 build 号是**一次性
# 快照**，谁绕过 --apply 直接 archive，号就不动（PendingCrew 机长 4-1 指出 ——
# 他那边构建时现算、值不落盘，没这个问题）。占位符 "1" 会被 ASC 当场拒收，
# 所以最坏也是响的失败，但白跑一次 archive 要好几分钟。--check 让它在
# archive 之前就响。
#
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
project_yml="$repo_root/apps/pendingbot/project.yml"
guard="$repo_root/scripts/release/asc_highest_build.py"

apply=0
check=0
print_only=0
for arg in "$@"; do
  case "$arg" in
    --apply) apply=1 ;;
    --check) check=1 ;;
    --print-only) print_only=1 ;;
    -h|--help)
      # 打印文件头整段注释（到第一行非注释为止），别写死行号 —— 写死过就会漂。
      awk 'NR>1 && !/^#/ { exit } NR>1 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *) echo "未知参数: $arg" >&2; exit 2 ;;
  esac
done

# --- 1. 算候选 build 号 -----------------------------------------------------
# 一次取时钟，两段都从它派生 —— 分两次读时钟会在跨秒/跨日的瞬间撕成两个不同
# 时刻（拿到今天的日期 + 明天 00:00:00 的秒数）。
now_epoch="$(date -u +%s)"
now_human="$(date -u -r "$now_epoch" +'%Y-%m-%d %H:%M:%SZ')"

if [ "$check" = "1" ]; then
  # 断言模式：不算新号，核 project.yml 里现在写着的那个。
  candidate="$(/usr/bin/sed -n -E 's/^ *CURRENT_PROJECT_VERSION: *"?([^"]*)"? *$/\1/p' "$project_yml")"
  [ -n "$candidate" ] || { echo "读不出 $project_yml 里的 CURRENT_PROJECT_VERSION" >&2; exit 1; }
  now_human="project.yml 里现有的值"
else
  candidate="$(printf '%d.%05d' "$((now_epoch / 86400))" "$((now_epoch % 86400))")"
fi

# 没有「备用格式」开关，这是有意的。曾经留过一个，实测后删了：备用格式想接在
# 主格式后面用，就得比主格式**大**，而任何"更安全所以更小"的编码天生做不到 ——
# 第一个主格式 build 一旦落地 ASC，那个备用就永远切不过去，留着只会让人在真
# 出事时白试一轮。
#
# 真正一直可用的 escape hatch 是另一个：TN2420 说 iOS 允许**换
# MARKETING_VERSION 后重用 build 号**（macOS 不允许）。所以万一哪天 ASC 对
# 当前格式有意见，正解是升 MARKETING_VERSION 另起一条 release train，
# 不是在 build 号编码上找花样。
#
# 旧文档教过 BUILD_NUMBER_FORMAT=dotted。开关已删，但静默忽略等于骗人 ——
# 有人以为切了格式，实际拿到的还是默认。报错，别静默。
if [ -n "${BUILD_NUMBER_FORMAT:-}" ]; then
  echo "BUILD_NUMBER_FORMAT 已废弃（收到: $BUILD_NUMBER_FORMAT）。" >&2
  echo "备用格式那条路走不通，原因见本文件注释；真要换编码得升 MARKETING_VERSION。" >&2
  exit 2
fi

# --- 2. 防倒退闸：跟 ASC 上已有的最高 build 号比 ----------------------------
# 取不到就停，不放行。ASC 瞬时故障由 asc_highest_build.py 内部有限重试兜。
if [ "$print_only" = "1" ]; then
  [ "$apply" = "0" ] && [ "$check" = "0" ] \
    || { echo "--print-only 不能和 --apply / --check 一起用" >&2; exit 2; }
  echo "$candidate"
  echo "build $candidate = $now_human（--print-only：跳过 ASC 闸，理由见文件头）" >&2
  exit 0
fi

highest="$(/usr/bin/python3 "$guard")"

if ! /usr/bin/python3 "$guard" --greater "$candidate" "$highest"; then
  if [ "$check" = "1" ]; then
    cat >&2 <<EOF
project.yml 里的 build 号发不出去，别 archive。
  project.yml : $candidate
  ASC 上最高  : $highest
八成是**忘了跑 --apply** —— 那个值是一次性快照，不重跑就不动（"1" 是占位符）。
先跑: scripts/release/ios-build-number.sh --apply
EOF
  else
    cat >&2 <<EOF
build 号没有严格递增，拒绝发版。
  这次算出来 : $candidate
  ASC 上最高 : $highest
时间戳理论上不该走到这儿。真走到了，说明要么系统时钟不对，要么有人手工传过
一个未来的 build 号 —— 两种都得先弄清楚，不要绕过这道闸。
EOF
  fi
  exit 1
fi

echo "$candidate"

# 纪元日不可读是有意的，但「不可读」不等于「查不到」。把可读形式打出来，
# 发版时抄进 TestFlight 的 What to Test，别让这笔账无声地记在以后每次
# 「这个 build 到底是什么时候的」上。
# 事后反查任意一个 build 号 <天>.<秒>：date -u -r $(( 天 * 86400 + 秒 ))
echo "build $candidate = $now_human（ASC 当前最高: $highest）" >&2

# --- 3. 可选：写进 project.yml 并重生 xcodeproj ------------------------------
if [ "$apply" = "1" ]; then
  /usr/bin/sed -i '' -E "s/^( *CURRENT_PROJECT_VERSION: ).*/\1\"$candidate\"/" "$project_yml"
  grep -q "CURRENT_PROJECT_VERSION: \"$candidate\"" "$project_yml" || {
    echo "写 project.yml 失败：没找到 CURRENT_PROJECT_VERSION 行" >&2
    exit 1
  }
  ( cd "$repo_root/apps/pendingbot" && xcodegen )
  echo "已写入 $project_yml 并重生 xcodeproj" >&2
fi
