#!/usr/bin/env bash
# Gate for what a public snapshot is allowed to contain.
#
# Reads scripts/snapshot-exclusions.tsv — which carries the reasoning, read it
# before changing anything here — and applies it to a candidate snapshot
# directory as **one allow list over the whole tree**:
#
#   registered ALLOW  → ships.
#   registered BLOCK  → does not ship, and BLOCK wins over ALLOW so that a
#                       hole can be punched inside an allowed subtree.
#   neither           → does not ship, and that is a failure. 默认是「不发」。
#
# It used to be two rules (docs/** allow, everything else block). That fitted a
# public repo that mirrored the whole monorepo. The public repo is now the
# client only — most of the tree does not go out — so the default flipped. The
# .tsv header tells that story next to the rows; this file only enforces it.
#
# The one thing worth knowing here rather than there: because BLOCK wins, a
# BLOCK row that covers an ALLOW row would silently cancel it. That is a
# contradiction in the list, not a policy, so it is a setup error (exit 2), not
# a quiet exclusion.
#
# Usage:
#   scripts/check-snapshot-exclusions.sh --candidate <dir>
#   scripts/check-snapshot-exclusions.sh --candidate <dir> --list <file>
#
# Exit codes: 0 clean · 1 something is in there that should not be · 2 usage.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
list="${SNAPSHOT_EXCLUSIONS:-$here/snapshot-exclusions.tsv}"
candidate=""

while [ $# -gt 0 ]; do
  case "$1" in
    --candidate) candidate="${2:-}"; shift 2 ;;
    --list)      list="${2:-}"; shift 2 ;;
    -h|--help)   sed -n '2,27p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$candidate" ] || { echo "--candidate <dir> is required" >&2; exit 2; }
[ -d "$candidate" ] || { echo "no such directory: $candidate" >&2; exit 2; }
[ -f "$list" ]      || { echo "no such list: $list" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ── The candidate's files ───────────────────────────────────────────────────
if git -C "$candidate" rev-parse --git-dir >/dev/null 2>&1 \
   && [ -n "$(git -C "$candidate" ls-files | head -1)" ]; then
  git -C "$candidate" ls-files | sort -u > "$work/files.txt"
  kind="tracked files"
else
  ( cd "$candidate" && find . -type f \
      -not -path './.git/*' -not -path '*/node_modules/*' \
      | sed 's|^\./||' ) | sort -u > "$work/files.txt"
  kind="files on disk"
fi

: > "$work/allow.txt"
: > "$work/block.tsv"
while IFS=$'\t' read -r mode pat why; do
  case "${mode:-}" in
    ''|'#'*) continue ;;
    ALLOW) printf '%s\n' "$pat" >> "$work/allow.txt" ;;
    BLOCK) printf '%s\t%s\n' "$pat" "$why" >> "$work/block.tsv" ;;
    *) echo "bad mode in $list: '$mode' (must be ALLOW or BLOCK)" >&2; exit 2 ;;
  esac
done < "$list"

echo "candidate : $candidate ($(wc -l < "$work/files.txt" | tr -d ' ') $kind)"
echo "list      : $list ($(wc -l < "$work/allow.txt" | tr -d ' ') allow · $(wc -l < "$work/block.tsv" | tr -d ' ') block)"
echo

# `**` in the list means "and everything beneath"; bash's plain globbing does
# not, so expand it to a prefix test.
matches() { # path pattern
  local path="$1" pat="$2"
  case "$pat" in
    */\*\*) [ "${path#"${pat%\*\*}"}" != "$path" ] && return 0 ;;
  esac
  # shellcheck disable=SC2254  # pattern is meant to glob
  case "$path" in $pat) return 0 ;; esac
  return 1
}

blocked_by() { # path -> prints "pattern<TAB>判词" and returns 0 when blocked
  local path="$1" pat why
  while IFS=$'\t' read -r pat why; do
    [ -z "${pat:-}" ] && continue
    if matches "$path" "$pat"; then printf '%s\t%s' "$pat" "$why"; return 0; fi
  done < "$work/block.tsv"
  return 1
}

# ── The list must not contradict itself ─────────────────────────────────────
# A BLOCK that covers an ALLOW would cancel it without saying so. Only literal
# ALLOW paths can be tested this way (a glob has no single path to test), which
# is fine: that is the shape the mistake takes.
: > "$work/contradictions.txt"
while IFS= read -r apat; do
  case "$apat" in *'*'*) continue ;; esac
  if hit="$(blocked_by "$apat")"; then
    printf '%s\t%s\n' "$apat" "${hit%%$'\t'*}" >> "$work/contradictions.txt"
  fi
done < "$work/allow.txt"

if [ -s "$work/contradictions.txt" ]; then
  echo "LIST CONTRADICTS ITSELF — BLOCK 优先于 ALLOW，下面每一行的 ALLOW 都被盖掉了：" >&2
  while IFS=$'\t' read -r apat bpat; do
    printf '  ALLOW %s\n      被 BLOCK %s 盖住\n' "$apat" "$bpat" >&2
  done < "$work/contradictions.txt"
  echo >&2
  echo "  这是清单写错了，不是一条政策，所以不当成「悄悄排除」处理。要么删掉那条" >&2
  echo "  BLOCK，要么把它写窄，让它不覆盖这个路径。" >&2
  exit 2
fi

: > "$work/unregistered.txt"
: > "$work/blocked.tsv"

while IFS= read -r path; do
  [ -z "$path" ] && continue

  if hit="$(blocked_by "$path")"; then
    printf '%s\t%s\n' "$path" "$hit" >> "$work/blocked.tsv"
    continue
  fi

  allowed=0
  while IFS= read -r pat; do
    [ -z "${pat:-}" ] && continue
    if matches "$path" "$pat"; then allowed=1; break; fi
  done < "$work/allow.txt"
  [ "$allowed" -eq 1 ] || printf '%s\n' "$path" >> "$work/unregistered.txt"
done < "$work/files.txt"

blocked=$(wc -l < "$work/blocked.tsv" | tr -d ' ')
unreg=$(wc -l < "$work/unregistered.txt" | tr -d ' ')

if [ "$blocked" -eq 0 ] && [ "$unreg" -eq 0 ]; then
  echo "clean — 快照里的每一个文件都在清单上登记过。"
  exit 0
fi

if [ "$blocked" -gt 0 ]; then
  echo "BLOCKED PATHS PRESENT ($blocked):"
  while IFS=$'\t' read -r path pat why; do
    printf '  %s\n      规则：%s\n      判词：%s\n' "$path" "$pat" "$why"
  done < "$work/blocked.tsv"
  echo
fi

if [ "$unreg" -gt 0 ]; then
  echo "UNREGISTERED PATHS ($unreg):"
  sed 's/^/  /' "$work/unregistered.txt"
  echo
  echo "  这是一份 allow list：没登记就不进。公开仓只放客户端，绝大部分内容本来"
  echo "  就不该出去，所以默认是「不发」。这些确实该给外部读者看的话，往"
  echo "  $list 加一行 ALLOW 并写清判词；否则把它们"
  echo "  从快照里去掉。"
  echo
fi

exit 1
