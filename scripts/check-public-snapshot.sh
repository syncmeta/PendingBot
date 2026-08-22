#!/usr/bin/env bash
# Fail if a candidate public snapshot still contains anything listed in
# docs/public-snapshot-exclude.txt.
#
# Usage:
#   bash scripts/check-public-snapshot.sh <snapshot-dir>
#   bun run snapshot:check <snapshot-dir>
#
# Wire this into whatever produces the public snapshot, immediately before the
# commit/push that publishes it. It is deliberately dumb — it checks for
# presence, not content — because the decision "this file does not go out" is
# made once, in the manifest, and then enforced every time by a machine.
#
# Exit codes: 0 clean, 1 something excluded is present, 2 usage/setup error.

set -euo pipefail

MANIFEST="${MANIFEST:-docs/public-snapshot-exclude.txt}"
TARGET="${1:-}"

if [[ -z "$TARGET" ]]; then
  echo "usage: $0 <snapshot-dir>" >&2
  exit 2
fi
if [[ ! -d "$TARGET" ]]; then
  echo "not a directory: $TARGET" >&2
  exit 2
fi
if [[ ! -f "$MANIFEST" ]]; then
  echo "manifest not found: $MANIFEST" >&2
  exit 2
fi

found=0
checked=0

while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"
  # trim surrounding whitespace
  line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [[ -z "$line" ]] && continue
  checked=$((checked + 1))

  # Glob expansion happens against the snapshot dir, not the repo.
  #
  # nullglob only drops patterns that *contain* wildcards; a literal path with
  # no metacharacters is left as-is whether or not it exists. Test each
  # candidate for real — otherwise every literal line in the manifest reports as
  # present and the check is a permanent, meaningless red.
  shopt -s nullglob dotglob
  matches=("$TARGET"/$line)
  shopt -u nullglob dotglob

  for m in "${matches[@]}"; do
    [[ -e "$m" ]] || continue
    echo "BLOCK ${m#"$TARGET"/} — listed in $MANIFEST, must not be published" >&2
    found=$((found + 1))
  done
done < "$MANIFEST"

if (( checked == 0 )); then
  echo "manifest $MANIFEST has no entries — refusing to report a pass" >&2
  exit 2
fi

if (( found > 0 )); then
  echo "" >&2
  echo "$found excluded path(s) present in $TARGET. Remove them from the snapshot, or" >&2
  echo "if one genuinely stopped being sensitive, delete its line from $MANIFEST and" >&2
  echo "say why in the commit message." >&2
  exit 1
fi

echo "Public snapshot check passed ($checked manifest entr$( ((checked==1)) && echo y || echo ies), 0 present in $TARGET)."
