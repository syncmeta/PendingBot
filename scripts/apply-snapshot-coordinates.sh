#!/usr/bin/env bash
# Replace the author's real coordinates with placeholders, in place, inside a
# candidate snapshot directory.
#
# Reads the same scripts/snapshot-coordinates.tsv that
# check-snapshot-coordinates.sh reads — one list, so "what got swapped" and
# "what gets checked" cannot drift apart.
#
# SWAP rows get replaced. **HOLD rows do not** — a HOLD is an open
# disagreement that a tool must not settle, so this script leaves the file
# alone and exits non-zero. Generation stops there rather than continuing with
# a warning nobody reads.
#
# **Only ever point this at a candidate snapshot directory.** It rewrites files
# in place. It refuses to run on a git working tree, because the one thing it
# must never do is quietly replace the real coordinates in the private repo —
# that would break the app for the author and look like a mystery.
#
# Usage:
#   scripts/apply-snapshot-coordinates.sh --candidate <dir>
#
# Exit codes: 0 done · 2 usage / refused.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
list="${SNAPSHOT_COORDINATES:-$here/snapshot-coordinates.tsv}"
candidate=""

while [ $# -gt 0 ]; do
  case "$1" in
    --candidate) candidate="${2:-}"; shift 2 ;;
    --list)      list="${2:-}"; shift 2 ;;
    -h|--help)   sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$candidate" ] || { echo "--candidate <dir> is required" >&2; exit 2; }
[ -d "$candidate" ] || { echo "no such directory: $candidate" >&2; exit 2; }
[ -f "$list" ]      || { echo "no such list: $list" >&2; exit 2; }

if git -C "$candidate" rev-parse --git-dir >/dev/null 2>&1; then
  echo "refusing: $candidate is inside a git working tree." >&2
  echo "This rewrites files in place and is meant for a candidate snapshot" >&2
  echo "directory only. Replacing the real coordinates in the private repo" >&2
  echo "would break the app for the author, silently." >&2
  exit 2
fi

changed=0
held=0
while IFS=$'\t' read -r mode scope real ph why; do
  case "${mode:-}" in ''|'#'*) continue ;; esac
  case "$mode" in
    SWAP|HOLD) ;;
    *) echo "bad mode in $list: '$mode' (must be SWAP or HOLD)" >&2; exit 2 ;;
  esac
  [ -n "${real:-}" ] || continue

  # HOLD: an open disagreement. Do not touch the file, do not pick a side —
  # picking one silently is exactly the failure this row exists to prevent.
  if [ "$mode" = HOLD ]; then
    if { [ "$scope" = '**' ] && grep -rqIF -- "$real" "$candidate" 2>/dev/null; } \
       || { [ -f "$candidate/$scope" ] && grep -qIF -- "$real" "$candidate/$scope" 2>/dev/null; }; then
      echo "HOLD  $scope  ←  $real"
      echo "      $why"
      held=$((held + 1))
    fi
    continue
  fi

  # while-read rather than mapfile: macOS still ships bash 3.2 and this script
  # has no business needing a newer one.
  targets=()
  if [ "$scope" = '**' ]; then
    while IFS= read -r t; do
      [ -n "$t" ] && targets+=("$t")
    done < <(grep -rlIF -- "$real" "$candidate" 2>/dev/null || true)
  else
    if [ -f "$candidate/$scope" ] && grep -qIF -- "$real" "$candidate/$scope" 2>/dev/null; then
      targets=("$candidate/$scope")
    fi
  fi

  for f in ${targets+"${targets[@]}"}; do
    [ -n "$f" ] || continue
    # \Q…\E so the needle is a literal; the replacement comes from the
    # environment so nothing in it is interpreted either.
    REAL="$real" PH="$ph" perl -0777 -pi -e 's/\Q$ENV{REAL}\E/$ENV{PH}/g' "$f"
    echo "  ${f#"$candidate"/}  ←  $real"
    changed=$((changed + 1))
  done
done < "$list"

echo
if [ "$held" -gt 0 ]; then
  echo "停在这儿：有 $held 条 HOLD 没解决。" >&2
  echo >&2
  echo "  HOLD 是「这里有个分歧，而它不该由工具挑边」。上面每一条的判词写了是什么" >&2
  echo "  分歧、该问谁。拿到答复之后，把 $list 里那一行" >&2
  echo "  改成 SWAP 或者删掉，再重跑。" >&2
  echo >&2
  echo "  已经做掉的 $changed 处替换留在候选目录里了 —— 但这份候选**不许出**，" >&2
  echo "  check-snapshot-coordinates.sh 也会红。" >&2
  exit 2
fi
echo "替换了 $changed 处。现在跑 check-snapshot-coordinates.sh 复查 —— 替换脚本自己说没问题不算数。"
