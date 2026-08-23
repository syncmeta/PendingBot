#!/usr/bin/env bash
# Replace the author's real coordinates with placeholders, in place, inside a
# candidate snapshot directory.
#
# Reads the same scripts/snapshot-coordinates.tsv that
# check-snapshot-coordinates.sh reads — one list, so "what got swapped" and
# "what gets checked" cannot drift apart.
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
while IFS=$'\t' read -r scope real ph why; do
  case "${scope:-}" in ''|'#'*) continue ;; esac
  [ -n "${real:-}" ] || continue

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
echo "替换了 $changed 处。现在跑 check-snapshot-coordinates.sh 复查 —— 替换脚本自己说没问题不算数。"
