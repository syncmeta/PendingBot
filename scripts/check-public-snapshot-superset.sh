#!/usr/bin/env bash
# Fail-closed gate for regenerating the public snapshot: a new snapshot must
# not silently drop anything that is already published.
#
# The hazard is specific and it has already bitten once. The public repo is
# described as "a clean snapshot of private main", and that sentence sounds
# completely true — it was true the first time. But the first snapshot also
# folded in four branches that were not on main yet, and picked up files that
# were authored directly in the snapshot (CONTRIBUTING.md, SECURITY.md, the
# issue templates, the vendored Apache license…). Regenerate naively "from
# main" and all of it disappears from a repo the world already has.
#
# So the reference is not a list anyone maintains — a list would rot, and rot
# silently. The reference is **what is published right now**, read live from
# the public remote. That fact cannot drift and nobody has to remember it.
#
#   candidate snapshot  ⊇  published main
#
# Two severities:
#   * supabase/migrations/**  — hard failure, no override. A published
#     migration that vanishes means anyone who already ran `db reset` has a
#     database the repo can no longer reproduce. (The one that made this
#     concrete: 20260820073931_revoke_public_execute_upsert_self_machine.sql
#     was published in the snapshot before it was merged to private main, so
#     for a while the public repo was the *safer* of the two — a direction
#     reversed enough that nobody would think to check it.)
#   * everything else — failure too, but droppable per path with
#     --allow-drop, so removing something is a deliberate, printed act
#     instead of a silent one.
#
# Usage:
#   scripts/check-public-snapshot-superset.sh --candidate <dir>
#   scripts/check-public-snapshot-superset.sh --candidate <dir> \
#       --allow-drop docs/old-thing.md --allow-drop 'infra/**'
#
#   --public-repo URL     default https://github.com/syncmeta/PendingBot.git
#   --public-ref  REF     default main
#   --public-list FILE    read the published file list from FILE instead of
#                         the network (for testing this script offline)
#
# Exit codes: 0 superset holds · 1 something published would be lost · 2 usage.

set -uo pipefail

PUBLIC_REPO="${SNAPSHOT_PUBLIC_REPO:-https://github.com/syncmeta/PendingBot.git}"
PUBLIC_REF="${SNAPSHOT_PUBLIC_REF:-main}"
candidate=""
public_list=""
allow_drops=()

while [ $# -gt 0 ]; do
  case "$1" in
    --candidate)   candidate="${2:-}"; shift 2 ;;
    --public-repo) PUBLIC_REPO="${2:-}"; shift 2 ;;
    --public-ref)  PUBLIC_REF="${2:-}"; shift 2 ;;
    --public-list) public_list="${2:-}"; shift 2 ;;
    --allow-drop)  allow_drops+=("${2:-}"); shift 2 ;;
    -h|--help)     sed -n '2,48p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$candidate" ] || { echo "--candidate <dir> is required" >&2; exit 2; }
[ -d "$candidate" ] || { echo "no such directory: $candidate" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ── What is published right now ─────────────────────────────────────────────
if [ -n "$public_list" ]; then
  [ -f "$public_list" ] || { echo "no such file: $public_list" >&2; exit 2; }
  sort -u "$public_list" > "$work/published.txt"
  published_at="(from $public_list)"
else
  git init -q "$work/pub" || exit 2
  git -C "$work/pub" remote add origin "$PUBLIC_REPO" || exit 2
  if ! git -C "$work/pub" fetch -q --depth=1 origin "$PUBLIC_REF" 2>"$work/fetch.err"; then
    echo "could not fetch $PUBLIC_REF from $PUBLIC_REPO:" >&2
    sed 's/^/  /' "$work/fetch.err" >&2
    echo >&2
    echo "This gate is fail-closed on purpose: if the published state cannot be" >&2
    echo "read, it cannot be compared, so the snapshot is not cleared." >&2
    exit 1
  fi
  git -C "$work/pub" ls-tree -r --name-only FETCH_HEAD | sort -u > "$work/published.txt"
  published_at="$(git -C "$work/pub" rev-parse --short FETCH_HEAD)"
fi

# ── What the candidate snapshot has ─────────────────────────────────────────
# Tracked files if it is already a git repo, otherwise everything on disk
# minus the usual build noise — a snapshot is often checked before its first
# commit exists.
if git -C "$candidate" rev-parse --git-dir >/dev/null 2>&1 \
   && [ -n "$(git -C "$candidate" ls-files | head -1)" ]; then
  git -C "$candidate" ls-files | sort -u > "$work/candidate.txt"
  candidate_kind="tracked files"
else
  ( cd "$candidate" && find . -type f \
      -not -path './.git/*' -not -path '*/node_modules/*' \
      | sed 's|^\./||' ) | sort -u > "$work/candidate.txt"
  candidate_kind="files on disk"
fi

echo "published : $PUBLIC_REPO@$PUBLIC_REF  $published_at  ($(wc -l < "$work/published.txt" | tr -d ' ') files)"
echo "candidate : $candidate  ($(wc -l < "$work/candidate.txt" | tr -d ' ') $candidate_kind)"
echo

comm -23 "$work/published.txt" "$work/candidate.txt" > "$work/missing.txt"

# ── Split by severity ───────────────────────────────────────────────────────
: > "$work/hard.txt"
: > "$work/soft.txt"
: > "$work/dropped.txt"

while IFS= read -r path; do
  [ -z "$path" ] && continue
  case "$path" in
    supabase/migrations/*)
      echo "$path" >> "$work/hard.txt"
      continue
      ;;
  esac
  allowed=0
  for pat in ${allow_drops+"${allow_drops[@]}"}; do
    # shellcheck disable=SC2254  # pattern is meant to glob
    case "$path" in $pat) allowed=1; break ;; esac
  done
  if [ "$allowed" -eq 1 ]; then
    echo "$path" >> "$work/dropped.txt"
  else
    echo "$path" >> "$work/soft.txt"
  fi
done < "$work/missing.txt"

hard=$(wc -l < "$work/hard.txt" | tr -d ' ')
soft=$(wc -l < "$work/soft.txt" | tr -d ' ')
dropped=$(wc -l < "$work/dropped.txt" | tr -d ' ')

if [ "$dropped" -gt 0 ]; then
  echo "DELIBERATELY DROPPED ($dropped) — allowed by --allow-drop, printed so it is never silent:"
  sed 's/^/  /' "$work/dropped.txt"
  echo
fi

if [ "$hard" -eq 0 ] && [ "$soft" -eq 0 ]; then
  echo "superset holds — nothing published would be lost."
  exit 0
fi

if [ "$hard" -gt 0 ]; then
  echo "PUBLISHED MIGRATIONS MISSING FROM THE SNAPSHOT ($hard) — hard stop, not overridable:"
  sed 's/^/  /' "$work/hard.txt"
  echo
  echo "  A migration that is already public cannot be un-published. Anyone who"
  echo "  ran \`supabase db reset\` against the published repo has a database this"
  echo "  snapshot can no longer reproduce. Find where the migration lives —"
  echo "  usually an unmerged branch — and include it."
  echo
fi

if [ "$soft" -gt 0 ]; then
  echo "OTHER PUBLISHED FILES MISSING FROM THE SNAPSHOT ($soft):"
  sed 's/^/  /' "$work/soft.txt"
  echo
  echo "  These are already in a repo the world has. Either bring them along, or"
  echo "  pass --allow-drop <path> to say out loud that you meant to remove them."
  echo
fi

exit 1
