#!/usr/bin/env bash
# Fail-closed gate: a candidate snapshot must not carry any of the author's
# real coordinates.
#
# Reads scripts/snapshot-coordinates.tsv — the reasoning lives in its header,
# read that before changing anything here. Short version: the placeholder
# values are what `HostedConfig.isConfigured` compares against, so swapping the
# coordinates is not redaction, it is what makes the fail-loud check work. One
# row (the author's personal email) is genuinely sensitive.
#
# Three row kinds.
#
#   SWAP   the ones above: replace this value with that placeholder.
#   HOLD   **an open disagreement that a tool must not settle** — the row names
#          a string, and while that string is still in the candidate, the
#          snapshot does not go out. It halts generation rather than printing a
#          warning, because a warning is just "remember to deal with this", and
#          remembering is the thing every gate in this repo exists to replace.
#   MATCH  this file must be byte-identical to **the published one**. Not a
#          hash copied in here — a hash copied in here drifts, and drifts
#          unnoticed. The reference is read live from the public remote.
#
# ⚠️ **MATCH needs the network.** One MATCH row and this gate stops being
# offline. Deliberate, and fail-closed the same way the superset gate is: if
# the published side cannot be read, it does not pass. Override the remote with
# SNAPSHOT_PUBLIC_REPO / SNAPSHOT_PUBLIC_REF, or point --public-list at a local
# file when you need to run it offline (testing).
#
# This gate exists because the swap used to be a step someone had to remember.
# On 2026-08-23 a candidate snapshot was generated straight out of `git
# archive` and every real value went with it. Nothing caught that, because
# nothing was watching.
#
# Usage:
#   scripts/check-snapshot-coordinates.sh --candidate <dir>
#   scripts/check-snapshot-coordinates.sh --candidate <dir> --list <file>
#
# Exit codes: 0 clean · 1 a real coordinate is still in there · 2 usage.
# ---8<--- help ends here ---8<---
# （--help 打到这条线为止；写死行号会悄悄切错，见 check-public-snapshot-superset.sh 的说明。）

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
list="${SNAPSHOT_COORDINATES:-$here/snapshot-coordinates.tsv}"
candidate=""

while [ $# -gt 0 ]; do
  case "$1" in
    --candidate) candidate="${2:-}"; shift 2 ;;
    --list)      list="${2:-}"; shift 2 ;;
    -h|--help)     awk 'NR>1{if (/^# ---8<---/) exit; print}' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$candidate" ] || { echo "--candidate <dir> is required" >&2; exit 2; }
[ -d "$candidate" ] || { echo "no such directory: $candidate" >&2; exit 2; }
[ -f "$list" ]      || { echo "no such list: $list" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

rows=0
hits=0
holds=0
matches=0
mismatch=0
: > "$work/hits.txt"
: > "$work/holds.txt"
: > "$work/mismatch.txt"

# 已发布那侧，现读，只读一次。fail-closed：读不到就不通过 —— 跟超集闸门同一条规矩，
# 因为「参照物读不到」和「参照物一致」不是一回事，而它们在 exit 0 上长得一样。
PUBLIC_REPO="${SNAPSHOT_PUBLIC_REPO:-https://github.com/syncmeta/PendingBot.git}"
PUBLIC_REF="${SNAPSHOT_PUBLIC_REF:-main}"
fetched=0
fetch_published() {
  [ "$fetched" -eq 1 ] && return 0
  # 先说一句为什么要联网。断网的人该看到「它在做什么、为什么失败」，
  # 不是一个突然的超时。
  echo "清单里有 MATCH 行 → 需要从 $PUBLIC_REPO@$PUBLIC_REF 现读参照物…"
  git init -q "$work/pub" 2>/dev/null || { echo "git init failed" >&2; return 1; }
  git -C "$work/pub" remote add origin "$PUBLIC_REPO" 2>/dev/null
  if ! git -C "$work/pub" fetch -q --depth=1 origin "$PUBLIC_REF" 2>"$work/fetch.err"; then
    echo "MATCH 行需要读「已发布那份」，但读不到 $PUBLIC_REF @ $PUBLIC_REPO：" >&2
    sed 's/^/  /' "$work/fetch.err" >&2
    echo >&2
    echo "  这道闸是 fail-closed 的：参照物读不到就不算通过。" >&2
    return 1
  fi
  fetched=1
  return 0
}

while IFS=$'\t' read -r mode scope real ph why; do
  case "${mode:-}" in ''|'#'*) continue ;; esac
  case "$mode" in
    SWAP|HOLD|MATCH) ;;
    *) echo "bad mode in $list: '$mode' (must be SWAP, HOLD or MATCH)" >&2; exit 2 ;;
  esac
  [ -n "${real:-}" ] || continue
  rows=$((rows + 1))

  if [ "$mode" = MATCH ]; then
    matches=$((matches + 1))
    fetch_published || exit 1
    cand_file="$candidate/$scope"
    if [ ! -f "$cand_file" ]; then
      printf '%s\t%s\t%s\n' "$scope" "候选快照里没有这个文件" "$why" >> "$work/mismatch.txt"
      mismatch=$((mismatch + 1)); continue
    fi
    if ! git -C "$work/pub" cat-file -e "FETCH_HEAD:$scope" 2>/dev/null; then
      printf '%s\t%s\t%s\n' "$scope" "已发布那侧没有这个文件" "$why" >> "$work/mismatch.txt"
      mismatch=$((mismatch + 1)); continue
    fi
    if ! git -C "$work/pub" show "FETCH_HEAD:$scope" 2>/dev/null | cmp -s - "$cand_file"; then
      printf '%s\t%s\t%s\n' "$scope" "与已发布那份不同" "$why" >> "$work/mismatch.txt"
      mismatch=$((mismatch + 1))
    fi
    continue
  fi

  if [ "$scope" = '**' ]; then
    # -I skips binaries; a PNG that happens to contain the byte sequence is
    # not a leak of anything.
    found="$(grep -rlIF -- "$real" "$candidate" 2>/dev/null)"
  elif [ -f "$candidate/$scope" ] && grep -qIF -- "$real" "$candidate/$scope" 2>/dev/null; then
    found="$candidate/$scope"
  else
    found=""
  fi

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ "$mode" = HOLD ]; then
      printf '%s\t%s\t%s\n' "${f#"$candidate"/}" "$real" "$why" >> "$work/holds.txt"
      holds=$((holds + 1))
    else
      printf '%s\t%s\t%s\n' "${f#"$candidate"/}" "$real" "$why" >> "$work/hits.txt"
      hits=$((hits + 1))
    fi
  done <<EOF
$found
EOF
done < "$list"

echo "candidate : $candidate"
echo "list      : $list ($rows coordinates)"
echo

if [ "$hits" -eq 0 ] && [ "$holds" -eq 0 ] && [ "$mismatch" -eq 0 ]; then
  # 只说真的跑过的检查。清单里一条 MATCH 都没有时还宣称「MATCH 全都一致」，
  # 是一句空转的真话 —— 而一句空转的真话，正是「绿」这个信号最容易被掏空的方式。
  if [ "$matches" -gt 0 ]; then
    echo "clean — 没有真坐标、没有悬而未决的分歧，$matches 条 MATCH 都与已发布那份逐字节相同。"
  else
    echo "clean — 没有真坐标、没有悬而未决的分歧。（清单里没有 MATCH 行，所以这一轮没跟已发布那份比过任何东西。）"
  fi
  exit 0
fi

if [ "$mismatch" -gt 0 ]; then
  echo "MISMATCH — 与已发布那份不一致 ($mismatch):"
  while IFS=$'\t' read -r f what why; do
    printf '  %s\n      情况：%s\n      判词：%s\n' "$f" "$what" "$why"
  done < "$work/mismatch.txt"
  echo
  echo "  MATCH 行守的是一条**已经定下来、而且以后也得成立的事实**，不是一次性结论。"
  echo "  两边不一致时，正确的动作是去问它该以哪边为准 —— 不是把这一行删掉。"
  echo "  删掉之后这里会变绿，但那个绿的含义是「没人在看」，不是「两边一致」。"
  echo
fi

if [ "$holds" -gt 0 ]; then
  echo "HELD — 有分歧没解决，快照不许出 ($holds):"
  while IFS=$'\t' read -r f real why; do
    printf '  %s\n      命中：%s\n      判词：%s\n' "$f" "$real" "$why"
  done < "$work/holds.txt"
  echo
  echo "  **这一类不是替换脚本能修的。** HOLD 的意思是「这里有个分歧，而它不该由"
  echo "  工具挑边」—— 通常是身份、法律或产品口径的问题，要人拍板。"
  echo "  拿到答复之后，把 $list 里那一行改成"
  echo "  SWAP，或者直接删掉（因为源头已经改对了）。在那之前生成就是中止的，"
  echo "  这是有意的：一件重要的事不该只活在「记得」里。"
  echo
fi

if [ "$hits" -gt 0 ]; then
  echo "REAL COORDINATES STILL PRESENT ($hits):"
  while IFS=$'\t' read -r f real why; do
    printf '  %s\n      真值：%s\n      判词：%s\n' "$f" "$real" "$why"
  done < "$work/hits.txt"
  echo
  echo "  跑 scripts/apply-snapshot-coordinates.sh --candidate <dir> 换掉它们。"
  echo "  两个脚本读的是同一份清单，所以「换了什么」和「查什么」不会对不上。"
  echo
fi
exit 1
