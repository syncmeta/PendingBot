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
#   * supabase/migrations/**  — hard failure. A published migration that
#     vanishes means anyone who already ran `db reset` has a database the repo
#     can no longer reproduce. (The one that made this concrete:
#     20260820073931_revoke_public_execute_upsert_self_machine.sql was
#     published in the snapshot before it was merged to private main, so for a
#     while the public repo was the *safer* of the two — a direction reversed
#     enough that nobody would think to check it.)
#
#     This used to say "no override", and for the repo that existed then it was
#     right: a snapshot that keeps claiming to define a database must keep
#     every migration it ever published. It is no longer unconditional, because
#     a case turned up that the wording did not cover — see --scope-change.
#   * everything else — failure too, but droppable per path with --allow-drop
#     (glob allowed) or --allow-drop-file (one exact path per line, no globs),
#     so removing something is a deliberate, printed act instead of a silent one.
#
# Usage:
#   scripts/check-public-snapshot-superset.sh --candidate <dir>
#   scripts/check-public-snapshot-superset.sh --candidate <dir> \
#       --allow-drop docs/old-thing.md --allow-drop 'infra/**'
#   scripts/check-public-snapshot-superset.sh --candidate <dir> \
#       --allow-drop-file docs/snapshot-drops/2026-08-23-client-only.txt \
#       --scope-change '后端不再开源，supabase/ 整棵树离开本仓库范围'
#
#   --allow-drop-file FILE  every dropped path, one per line (# comments and
#                        blank lines skipped). **Exact match, never a glob** —
#                        that is the point: it makes "we removed 570 files"
#                        cost 570 lines in a file someone has to look at,
#                        instead of one wildcard nobody reads. The file is
#                        meant to be committed, so the question "what exactly
#                        did we delete back then" has an answer later.
#   --scope-change TEXT  lift the migrations hard stop, for the one case the
#                        hard stop was not written for: the repository no
#                        longer contains a database at all. Not an escape
#                        hatch for "this migration is inconvenient" — a
#                        migration can only be dropped under this flag if it
#                        is ALSO listed, by exact path, in the drop file. Two
#                        separate deliberate acts. TEXT is required, printed,
#                        and belongs in the commit message too.
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
allow_drop_file=""
scope_change=""

while [ $# -gt 0 ]; do
  case "$1" in
    --candidate)   candidate="${2:-}"; shift 2 ;;
    --public-repo) PUBLIC_REPO="${2:-}"; shift 2 ;;
    --public-ref)  PUBLIC_REF="${2:-}"; shift 2 ;;
    --public-list) public_list="${2:-}"; shift 2 ;;
    --allow-drop)  allow_drops+=("${2:-}"); shift 2 ;;
    --allow-drop-file) allow_drop_file="${2:-}"; shift 2 ;;
    --scope-change)    scope_change="${2:-}"; shift 2 ;;
    -h|--help)     sed -n '2,66p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$candidate" ] || { echo "--candidate <dir> is required" >&2; exit 2; }
[ -d "$candidate" ] || { echo "no such directory: $candidate" >&2; exit 2; }
if [ -n "$allow_drop_file" ] && [ ! -f "$allow_drop_file" ]; then
  echo "no such drop file: $allow_drop_file" >&2; exit 2
fi
if [ -n "$scope_change" ] && [ -z "$allow_drop_file" ]; then
  echo "--scope-change needs --allow-drop-file: a migration may only be dropped" >&2
  echo "when it is also listed by exact path. Two deliberate acts, not one flag." >&2
  exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Exact paths from the drop file. Sorted so the lookup below is a plain grep.
: > "$work/dropfile.txt"
if [ -n "$allow_drop_file" ]; then
  sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$allow_drop_file" \
    | grep -v '^[[:space:]]*$' | sort -u > "$work/dropfile.txt"
fi

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
  listed=0
  grep -qxF "$path" "$work/dropfile.txt" && listed=1

  case "$path" in
    supabase/migrations/*)
      # The hard stop, and the single documented way past it: the repository
      # is no longer claiming to define a database, AND this exact migration
      # is written down in the drop file.
      if [ -n "$scope_change" ] && [ "$listed" -eq 1 ]; then
        echo "$path" >> "$work/dropped.txt"
      else
        echo "$path" >> "$work/hard.txt"
      fi
      continue
      ;;
  esac
  allowed="$listed"
  if [ "$allowed" -eq 0 ]; then
    for pat in ${allow_drops+"${allow_drops[@]}"}; do
      # shellcheck disable=SC2254  # pattern is meant to glob
      case "$path" in $pat) allowed=1; break ;; esac
    done
  fi
  if [ "$allowed" -eq 1 ]; then
    echo "$path" >> "$work/dropped.txt"
  else
    echo "$path" >> "$work/soft.txt"
  fi
done < "$work/missing.txt"

hard=$(wc -l < "$work/hard.txt" | tr -d ' ')
soft=$(wc -l < "$work/soft.txt" | tr -d ' ')
dropped=$(wc -l < "$work/dropped.txt" | tr -d ' ')

if [ -n "$scope_change" ]; then
  echo "SCOPE CHANGE DECLARED — the migrations hard stop is lifted for this run."
  echo "  reason: $scope_change"
  echo "  Every dropped migration below is also listed by exact path in"
  echo "  $allow_drop_file. Anything published stays reachable in this"
  echo "  repository's history and tags; dropping it from the tree is not"
  echo "  un-publishing it."
  echo
fi

if [ "$dropped" -gt 0 ]; then
  echo "DELIBERATELY DROPPED ($dropped) — printed so it is never silent:"
  sed 's/^/  /' "$work/dropped.txt"
  echo
fi

if [ "$hard" -eq 0 ] && [ "$soft" -eq 0 ]; then
  if [ "$dropped" -gt 0 ]; then
    # Not "nothing was lost" — $dropped files were. Say which sentence is true.
    echo "superset holds for everything that was not dropped on purpose."
    echo "  $dropped published files were removed deliberately and are listed above."
  else
    echo "superset holds — nothing published would be lost."
  fi
  exit 0
fi

if [ "$hard" -gt 0 ]; then
  echo "PUBLISHED MIGRATIONS MISSING FROM THE SNAPSHOT ($hard) — hard stop:"
  sed 's/^/  /' "$work/hard.txt"
  echo
  echo "  A migration that is already public cannot be un-published. Anyone who"
  echo "  ran \`supabase db reset\` against the published repo has a database this"
  echo "  snapshot can no longer reproduce. Find where the migration lives —"
  echo "  usually an unmerged branch — and include it."
  echo
  echo "  If the repository genuinely no longer contains a database at all, that"
  echo "  is a scope change, not a lost migration: pass --scope-change '<why>'"
  echo "  and list every one of these paths in --allow-drop-file. Do not reach"
  echo "  for that to make one inconvenient migration go away."
  echo
fi

if [ "$soft" -gt 0 ]; then
  echo "OTHER PUBLISHED FILES MISSING FROM THE SNAPSHOT ($soft):"
  sed 's/^/  /' "$work/soft.txt"
  echo
  echo "  These are already in a repo the world has. Either bring them along, or"
  echo "  say out loud that you meant to remove them — --allow-drop <path> for a"
  echo "  few, --allow-drop-file <file> when it is many (one exact path per line,"
  echo "  and commit that file)."
  echo
fi

exit 1
