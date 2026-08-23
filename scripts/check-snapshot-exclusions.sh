#!/usr/bin/env bash
# Gate for what a public snapshot is allowed to contain.
#
# Reads scripts/snapshot-exclusions.tsv — which carries the reasoning, read it
# before changing anything here — and applies its two rules to a candidate
# snapshot directory:
#
#   docs/**          allow list. A file under docs/ that nobody registered is
#                    a failure. New internal documents get written all the
#                    time; none of them should reach the public repo just by
#                    existing.
#   everything else  block list. A registered path that made it into the
#                    snapshot is a failure.
#
# The asymmetry is deliberate. Its justification lives in the header of the
# .tsv, next to the rows, so that the next person to read the list sees why
# there are two rules rather than "tidying" them into one.
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
    -h|--help)   sed -n '2,24p' "$0"; exit 0 ;;
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

: > "$work/unregistered-docs.txt"
: > "$work/blocked.tsv"

while IFS= read -r path; do
  [ -z "$path" ] && continue

  hit=""
  while IFS=$'\t' read -r pat why; do
    [ -z "${pat:-}" ] && continue
    if matches "$path" "$pat"; then hit="$pat"$'\t'"$why"; break; fi
  done < "$work/block.tsv"
  if [ -n "$hit" ]; then
    printf '%s\t%s\n' "$path" "$hit" >> "$work/blocked.tsv"
    continue
  fi

  case "$path" in
    docs/*)
      if ! grep -qxF "$path" "$work/allow.txt"; then
        printf '%s\n' "$path" >> "$work/unregistered-docs.txt"
      fi
      ;;
  esac
done < "$work/files.txt"

blocked=$(wc -l < "$work/blocked.tsv" | tr -d ' ')
undocs=$(wc -l < "$work/unregistered-docs.txt" | tr -d ' ')

if [ "$blocked" -eq 0 ] && [ "$undocs" -eq 0 ]; then
  echo "clean — nothing in the snapshot that should not be."
  exit 0
fi

if [ "$blocked" -gt 0 ]; then
  echo "BLOCKED PATHS PRESENT ($blocked):"
  while IFS=$'\t' read -r path pat why; do
    printf '  %s\n      规则：%s\n      判词：%s\n' "$path" "$pat" "$why"
  done < "$work/blocked.tsv"
  echo
fi

if [ "$undocs" -gt 0 ]; then
  echo "UNREGISTERED docs/ FILES ($undocs):"
  sed 's/^/  /' "$work/unregistered-docs.txt"
  echo
  echo "  docs/ 是 allow list：没登记就不进。内部文档一直在产出，默认必须是"
  echo "  「不公开」。这份确实该给外部读者看的话，往 $list"
  echo "  加一行 ALLOW 并写清判词；否则把它从快照里去掉。"
  echo
fi

exit 1
