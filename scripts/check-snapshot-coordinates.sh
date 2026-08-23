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

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
list="${SNAPSHOT_COORDINATES:-$here/snapshot-coordinates.tsv}"
candidate=""

while [ $# -gt 0 ]; do
  case "$1" in
    --candidate) candidate="${2:-}"; shift 2 ;;
    --list)      list="${2:-}"; shift 2 ;;
    -h|--help)   sed -n '2,22p' "$0"; exit 0 ;;
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
: > "$work/hits.txt"

while IFS=$'\t' read -r scope real ph why; do
  case "${scope:-}" in ''|'#'*) continue ;; esac
  [ -n "${real:-}" ] || continue
  rows=$((rows + 1))

  if [ "$scope" = '**' ]; then
    # -I skips binaries; a PNG that happens to contain the byte sequence is
    # not a leak of anything.
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      printf '%s\t%s\t%s\n' "${f#"$candidate"/}" "$real" "$why" >> "$work/hits.txt"
      hits=$((hits + 1))
    done < <(grep -rlIF -- "$real" "$candidate" 2>/dev/null)
  else
    f="$candidate/$scope"
    if [ -f "$f" ] && grep -qIF -- "$real" "$f" 2>/dev/null; then
      printf '%s\t%s\t%s\n' "$scope" "$real" "$why" >> "$work/hits.txt"
      hits=$((hits + 1))
    fi
  fi
done < "$list"

echo "candidate : $candidate"
echo "list      : $list ($rows coordinates)"
echo

if [ "$hits" -eq 0 ]; then
  echo "clean — 候选快照里没有任何一条真坐标。"
  exit 0
fi

echo "REAL COORDINATES STILL PRESENT ($hits):"
while IFS=$'\t' read -r f real why; do
  printf '  %s\n      真值：%s\n      判词：%s\n' "$f" "$real" "$why"
done < "$work/hits.txt"
echo
echo "  跑 scripts/apply-snapshot-coordinates.sh --candidate <dir> 换掉它们。"
echo "  两个脚本读的是同一份清单，所以「换了什么」和「查什么」不会对不上。"
echo
exit 1
