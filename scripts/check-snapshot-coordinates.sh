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
# Two row kinds. SWAP rows are the ones above. **HOLD rows are an open
# disagreement that a tool must not settle** — the row names a string, and
# while that string is still in the candidate, the snapshot does not go out.
# It halts generation rather than printing a warning, because a warning is
# just "remember to deal with this", and remembering is the thing every gate
# in this repo exists to replace.
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
: > "$work/hits.txt"
: > "$work/holds.txt"

while IFS=$'\t' read -r mode scope real ph why; do
  case "${mode:-}" in ''|'#'*) continue ;; esac
  case "$mode" in
    SWAP|HOLD) ;;
    *) echo "bad mode in $list: '$mode' (must be SWAP or HOLD)" >&2; exit 2 ;;
  esac
  [ -n "${real:-}" ] || continue
  rows=$((rows + 1))

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

if [ "$hits" -eq 0 ] && [ "$holds" -eq 0 ]; then
  echo "clean — 候选快照里没有任何一条真坐标，也没有悬而未决的分歧。"
  exit 0
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
