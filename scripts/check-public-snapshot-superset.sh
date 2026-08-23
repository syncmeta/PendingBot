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
# ---8<--- help ends here ---8<---
# （--help 打到这条线为止。原来写的是 `sed -n '2,NNp'`，一个写死的行号 ——
#   往上面加两行它就少打两行，而且**不报错**，只是少打，没人会发现。
#
#   但真正的理由不是「有人填错了」。2026-08-23 两个人各自认真数了一遍「注释头到
#   哪儿结束」，五个脚本里有四个**逐条差 1** —— 因为两人用的判定边界不同
#   （数到第一个非注释行为止，还是连尾部那行空行一起算）。**这个数字本身就没有
#   一个所有人都同意的定义**，所以它不该由人来维护。哨兵把「头到哪儿结束」从一件
#   需要判断的事，变成一件写在文件里的事实。）
#
# ── 在给这道闸加例外之前，先读这一段 ────────────────────────────────────────
#
# **它只报事实，不猜动机。** 它看到的事实永远只有一件：一个已经发布出去的文件，
# 在新快照里没有了。**这次是不是有正当理由，是你的活，不是它的活。**
#
#   一道只在坏事发生时才响的闸，必然是在猜动机，
#   而猜错的那次就是它失效的那次。
#
# 所以**一次完全正当的改动照样会让它红**，这是设计，不是缺陷。真实例子
# （2026-08-23）：`GoogleG.imageset/g-logo.png` 换成官方 SVG —— 作者拍过板、
# 资源没丢、只是形式变了，这道闸照红。**红得对**：一个已发布的文件不见了，
# 这件事必须被打印出来、被人看一眼、被写进档，而不是因为理由充分就悄悄过去。
#
# 事实对而结论刺眼时，该做的是**把理由写进档**（丢弃清单、判词、提交信息），
# 不是让闸门闭嘴。为什么这句要写在这儿：不写的话，下一个人只会觉得这闸门爱误报，
# 然后给它加一堆例外 —— **那才是一道闸真正的死法，不是被拆掉，是被例外淹死。**
#
# 两条推论，同样算规矩：
#   * 别拿「上次也是误报」当判据。上次正当不代表这次正当 —— 那正是它存在的理由。
#   * 速查会失效，而失效的速查比没有速查更危险（它便宜、好记，所以还会有人用）。
#     发现一条不成立了，去它写着的地方划掉，别只在心里改。
#

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
    -h|--help)     awk 'NR>1{if (/^# ---8<---/) exit; print}' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$candidate" ] || { echo "--candidate <dir> is required" >&2; exit 2; }
[ -d "$candidate" ] || { echo "no such directory: $candidate" >&2; exit 2; }
if [ -n "$allow_drop_file" ] && [ ! -f "$allow_drop_file" ]; then
  echo "no such drop file: $allow_drop_file" >&2; exit 2
fi

# The drop file has to be a committed file, not a scratch file or a pipe.
# Its whole reason for existing is that someone can answer "what exactly did we
# delete back then" years later; a list that only existed for the length of one
# command answers nothing. Enforced rather than documented, because the sentence
# right above is the kind people agree with and then skip.
if [ -n "$allow_drop_file" ]; then
  gate_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if ! git -C "$gate_repo" ls-files --error-unmatch -- "$allow_drop_file" >/dev/null 2>&1; then
    echo "refusing: $allow_drop_file is not tracked by git in $gate_repo." >&2
    echo >&2
    echo "  The drop list must be committed. It is the only later answer to" >&2
    echo "  \"what exactly did we delete\" — a temp file answers nothing, and a" >&2
    echo "  list nobody can review is the same as a wildcard." >&2
    exit 2
  fi
fi

if [ -n "$scope_change" ] && [ -z "$allow_drop_file" ]; then
  echo "--scope-change needs --allow-drop-file: a migration may only be dropped" >&2
  echo "when it is also listed by exact path. Two deliberate acts, not one flag." >&2
  exit 2
fi

# --scope-change is the one switch here that can make an already-published
# database migration disappear. It is meant to be typed, once, by a person who
# has just decided that this repository no longer contains a database.
#
# Writing that in a comment would make it a convention, and this whole gate
# exists to stop conventions from being the thing that protects us. So: it
# refuses to run unattended. Wire it into CI or a script and it fails loudly
# instead of quietly doing the irreversible thing.
if [ -n "$scope_change" ]; then
  unattended=""
  [ -t 0 ] || unattended="stdin is not a terminal"
  for v in CI GITHUB_ACTIONS GITLAB_CI BUILDKITE JENKINS_URL TEAMCITY_VERSION; do
    eval "val=\${$v:-}"
    [ -n "$val" ] && unattended="\$$v is set"
  done
  if [ -n "$unattended" ]; then
    echo "refusing --scope-change: $unattended." >&2
    echo >&2
    echo "  This switch drops already-published database migrations. It is only" >&2
    echo "  allowed when a person types it in a terminal — deciding that the" >&2
    echo "  repository no longer contains a database is not a thing automation" >&2
    echo "  gets to decide on its own." >&2
    echo >&2
    echo "  Everything else this gate does still works unattended; run it" >&2
    echo "  without --scope-change." >&2
    exit 2
  fi
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
  echo "  这道闸不判断动机，只报事实：一个已发布的文件不见了。一次完全正当的改动"
  echo "  照样会红（例：g-logo.png 换成官方 SVG）。逐条看过之后登记进丢弃清单 ——"
  echo "  别给闸门加例外。理由见本脚本文件头。"
  echo
fi

exit 1
