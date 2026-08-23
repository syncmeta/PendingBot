#!/usr/bin/env bash
# Check every link in the reader-facing markdown and fail if any of them is
# dead. "Reader-facing" = anything a visitor to the public repo might click
# through; the default set is listed under Usage below.
#
# Why this exists: the release checklist used to say "click every link before
# publishing". Anything that depends on a person remembering eventually gets
# skipped — and a dead link on the front page of a public repo is the first
# thing a visitor hits. So the check is a machine's job.
#
# What it checks, by link kind:
#
#   https://…        HTTP request. Anything that isn't 2xx is a failure.
#                    Some hosts get a content assertion on top — see the
#                    body_rules table in section 3. Status code alone is not
#                    enough: an expired TestFlight beta and an App Store page
#                    outside your storefront both answer 200 while giving the
#                    reader nothing.
#   <https://…>      Same (markdown autolink).
#   ./relative.md    The file must exist on disk.
#   #anchor          A heading (or an explicit HTML id/name) with that slug
#                    must exist in the same file.
#   ../../releases   GitHub-relative. Resolved against the repo's origin
#                    remote when there is one; reported as UNCHECKED (not a
#                    failure) when there isn't, because there is nothing to
#                    resolve it against yet.
#   mailto:          Skipped.
#
# Fenced code blocks and inline code spans are skipped — example URLs in
# there are illustrations, not links a reader can click.
#
# Usage:
#   scripts/check-readme-links.sh                     # default file set
#                                                     # (README · README_EN ·
#                                                     #  CONTRIBUTING · SECURITY ·
#                                                     #  SNAPSHOT-PROVENANCE ·
#                                                     #  docs/building.md ·
#                                                     #  apps/pendingbot/README.md)
#   scripts/check-readme-links.sh README.md …         # explicit files
#   scripts/check-readme-links.sh --offline           # skip HTTP, local only
#   scripts/check-readme-links.sh --repo owner/name   # override the published repo
#   scripts/check-readme-links.sh --no-known-broken   # ignore the registry
#
# Links we cannot fix ourselves are registered in scripts/known-broken-links.tsv:
# they still print on every run, but as a warning, and only until the date on
# the row. Red stays reserved for a dead link nobody has accounted for — see
# section 4 for why that matters.
#
# Env overrides: LINK_CHECK_APP_NAME (the name the TestFlight page must
# show), LINK_CHECK_TIMEOUT / _RETRIES / _JOBS / _UA / _REPO.
#
# Exit codes: 0 all good · 1 at least one dead link · 2 bad usage.

set -uo pipefail

TIMEOUT="${LINK_CHECK_TIMEOUT:-20}"
RETRIES="${LINK_CHECK_RETRIES:-2}"
JOBS="${LINK_CHECK_JOBS:-8}"
UA="${LINK_CHECK_UA:-Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36}"

offline=0
repo_slug="${LINK_CHECK_REPO:-}"
registry="${LINK_CHECK_KNOWN_BROKEN:-scripts/known-broken-links.tsv}"
today="${LINK_CHECK_TODAY:-$(date -u +%Y-%m-%d)}"
files=()

while [ $# -gt 0 ]; do
  case "$1" in
    --offline) offline=1; shift ;;
    --repo) repo_slug="${2:-}"; shift 2 ;;
    --known-broken) registry="${2:-}"; shift 2 ;;
    --no-known-broken) registry=""; shift ;;
    -h|--help) sed -n '2,41p' "$0"; exit 0 ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) files+=("$1"); shift ;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 2

# The default set is "every markdown file a visitor to the public repo might
# click through". Guarded by -f because the set differs between the private
# tree and a candidate snapshot — a missing file is not an error, it just is
# not there to check.
if [ ${#files[@]} -eq 0 ]; then
  for f in README.md README_EN.md CONTRIBUTING.md SECURITY.md \
           SNAPSHOT-PROVENANCE.md docs/building.md apps/pendingbot/README.md; do
    [ -f "$f" ] && files+=("$f")
  done
fi
if [ ${#files[@]} -eq 0 ]; then
  echo "no reader-facing markdown found — nothing to check" >&2
  exit 2
fi

# Which repo is this README written to be read on?
#
# Not "whatever repo I happen to be sitting in". This README ships in the
# public snapshot, so `../../releases` means the PUBLIC repo's releases page,
# and a relative path missing here may well exist there. Run the same check
# from the private tree with the private origin as the reference and you get
# a 404 that says nothing about the README.
#
# This used to be a `--repo` flag the caller had to remember. It got
# forgotten on the very first run by someone else — which is the failure this
# whole gate exists to remove, showing up inside the gate itself. So the
# answer is baked in below, and the flag stays only as an override.
PUBLISHED_REPO_DEFAULT="${PUBLISHED_REPO_DEFAULT:-syncmeta/PendingBot}"
if [ -z "$repo_slug" ]; then
  repo_slug="$PUBLISHED_REPO_DEFAULT"
fi
# Nothing configured at all (someone reusing this script elsewhere): fall back
# to the origin remote, and report ../../ links as UNCHECKED if there is none.
if [ -z "$repo_slug" ]; then
  origin="$(git config --get remote.origin.url 2>/dev/null || true)"
  case "$origin" in
    git@github.com:*)     repo_slug="${origin#git@github.com:}";     repo_slug="${repo_slug%.git}" ;;
    https://github.com/*) repo_slug="${origin#https://github.com/}"; repo_slug="${repo_slug%.git}" ;;
  esac
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ── 1. Extract links ────────────────────────────────────────────────────────
# One TSV row per link: file <TAB> line <TAB> raw-url
extract_links() {
  local file="$1"
  awk -v F="$file" '
    /^[[:space:]]*(```|~~~)/ { fence = !fence; next }
    fence { next }
    { print F "\t" NR "\t" $0 }
  ' "$file" | python3 -c '
import re, sys

# ](url)                 markdown inline link / image
# href="url" src="url"   raw HTML (the README uses <p align="center"> blocks)
# <url>                  markdown autolink
PATTERNS = [
    re.compile(r"\]\(\s*<?([^)\s>]+)"),
    re.compile(r"(?:href|src)\s*=\s*[\"\x27]([^\"\x27]+)[\"\x27]"),
    re.compile(r"<((?:https?|mailto):[^>\s]+)>"),
]

for row in sys.stdin:
    parts = row.rstrip("\n").split("\t", 2)
    if len(parts) != 3:
        continue
    path, lineno, text = parts
    text = re.sub(r"`[^`]*`", "", text)   # inline code spans are examples
    seen = set()
    for pat in PATTERNS:
        for url in pat.findall(text):
            url = url.strip().rstrip(",.;")
            if not url or url in seen:
                continue
            seen.add(url)
            print(f"{path}\t{lineno}\t{url}")
'
}

: > "$work/links.tsv"
for f in "${files[@]}"; do
  [ -f "$f" ] || { echo "no such file: $f" >&2; exit 2; }
  extract_links "$f" >> "$work/links.tsv"
done

total=$(wc -l < "$work/links.tsv" | tr -d ' ')
echo "checking $total link(s) in: ${files[*]}"
[ "$offline" -eq 1 ] && echo "  (--offline: HTTP links are reported as UNCHECKED)"
[ -n "$repo_slug" ] && echo "  (github-relative links resolve against $repo_slug)"
echo

# A relative path can be missing here and present where the README is actually
# read — see the call site for the case that made this necessary.
probe_path_in_published_repo() {
  local path="$1" code
  code=$(curl -sS -o /dev/null -w '%{http_code}' -L \
           --max-time "$TIMEOUT" --retry 1 -A "$UA" \
           "https://raw.githubusercontent.com/$repo_slug/HEAD/$path" 2>/dev/null)
  case "$code" in 2*) return 0 ;; *) return 1 ;; esac
}

# ── 2. Local checks: relative paths and anchors ─────────────────────────────
# No network, so an offline run still catches the two mistakes that bite most
# often: a link to a file nobody ever wrote, and an anchor to a renamed heading.
slugify() {
  python3 - "$1" <<'PY'
import re, sys, unicodedata
s = unicodedata.normalize("NFC", sys.argv[1]).strip().lower()
s = re.sub(r"<[^>]+>", "", s)                     # inline html
s = re.sub(r"[`*_~\[\]()]", "", s)                # inline markup
# GitHub keeps letters/digits (CJK included), space and -_ ; everything
# else — punctuation, emoji — is dropped. Python's isalnum() draws that
# same line: True for 文, False for 🙏.
s = "".join(ch for ch in s if ch.isalnum() or ch in " -_")
print(s.replace(" ", "-"))
PY
}

anchors_of() {
  local file="$1"
  awk '/^[[:space:]]*(```|~~~)/ { fence = !fence; next }
       fence { next }
       /^#{1,6} / { sub(/^#{1,6} /, ""); print }' "$file" \
    | while IFS= read -r h; do slugify "$h"; done
  # `|| true`: a file with no explicit id=/name= anchors makes grep exit 1,
  # and under `set -o pipefail` that non-zero would propagate out of the
  # `anchors_of | grep -q` pipeline and turn every live anchor into a
  # false "dead link". Cost us one debugging round; keep the guard.
  grep -oE '(id|name)="[^"]+"' "$file" 2>/dev/null | sed 's/.*="//;s/"$//' || true
  return 0
}

: > "$work/http.tsv"
: > "$work/fail.tsv"
: > "$work/unchecked.txt"
: > "$work/elsewhere.txt"
local_ok=0

while IFS=$'\t' read -r file line url; do
  [ -z "${url:-}" ] && continue
  case "$url" in
    mailto:*|tel:*)
      ;;
    http://*|https://*)
      if [ "$offline" -eq 1 ]; then
        printf '%s:%s  %s  (--offline)\n' "$file" "$line" "$url" >> "$work/unchecked.txt"
      else
        printf '%s\t%s\t%s\n' "$file" "$line" "$url" >> "$work/http.tsv"
      fi
      ;;
    \#*)
      want="$(slugify "${url#\#}")"
      # Cache the file's anchors instead of recomputing (and re-SIGPIPE-ing
      # the slugify subprocesses) once per anchor link.
      cache="$work/anchors.$(echo "$file" | tr '/' '_')"
      [ -f "$cache" ] || anchors_of "$file" > "$cache"
      if grep -qxF "$want" "$cache"; then
        local_ok=$((local_ok + 1))
      else
        printf '%s\t%s\t%s\t%s\n' "$file" "$line" "$url" "no heading with that anchor in $file" >> "$work/fail.tsv"
      fi
      ;;
    ../../*)
      # `../../x` is ambiguous and both readings are real:
      #
      #   ../../releases            from the root README — a GitHub UI path.
      #                             There is no such file; GitHub resolves it
      #                             against the repo URL.
      #   ../../docs/building.md    from apps/pendingbot/README.md — an
      #                             ordinary relative path to a file that
      #                             exists. GitHub resolves it the same way a
      #                             browser would, and it works.
      #
      # So try the filesystem first and only fall back to the GitHub reading
      # when nothing is there. Treating every `../../` as a UI path produced a
      # confident 404 for a link that works for every actual reader — a gate
      # that cries false is a gate nobody reads.
      rel_target="$(cd "$(dirname "$file")" 2>/dev/null && cd "$(dirname "${url%%#*}")" 2>/dev/null && pwd)/$(basename "${url%%#*}")"
      # Must land inside the repo. `../../releases` from the root README walks
      # out of the tree entirely, and whatever sits up there is not this
      # repository's file — accepting it would be a false green that depends
      # on what else the checkout happens to live next to.
      case "$rel_target" in
        "$repo_root"/*) ;;
        *) rel_target="" ;;
      esac
      if [ -n "$rel_target" ] && [ -e "$rel_target" ]; then
        local_ok=$((local_ok + 1))
      elif [ -n "$repo_slug" ] && [ "$offline" -eq 0 ]; then
        printf '%s\t%s\thttps://github.com/%s/%s\n' "$file" "$line" "$repo_slug" "${url#../../}" >> "$work/http.tsv"
      else
        printf '%s:%s  %s  (github-relative; no origin remote to resolve it against)\n' \
          "$file" "$line" "$url" >> "$work/unchecked.txt"
      fi
      ;;
    *)
      target="$(dirname "$file")/${url%%#*}"
      target="${target#./}"
      if [ -e "$target" ]; then
        # A cross-file anchor is checked too, not just the file. `other.md#foo`
        # used to pass on the strength of other.md existing, which makes the
        # gate blind to exactly the link that breaks when someone renames a
        # heading. One of those headings is load-bearing: the app's own
        # "see the 配置 section of the README" notice is compiled into the
        # binary, so that heading cannot be renamed without shipping a build.
        frag="${url#*#}"
        if [ "$frag" != "$url" ] && [ -n "$frag" ] && case "$target" in *.md) true ;; *) false ;; esac; then
          want="$(slugify "$frag")"
          cache="$work/anchors.$(echo "$target" | tr '/' '_')"
          [ -f "$cache" ] || anchors_of "$target" > "$cache"
          if grep -qxF "$want" "$cache"; then
            local_ok=$((local_ok + 1))
          else
            printf '%s\t%s\t%s\t%s\n' "$file" "$line" "$url" "no heading with that anchor in $target" >> "$work/fail.tsv"
          fi
          continue
        fi
        local_ok=$((local_ok + 1))
      elif [ -n "$repo_slug" ] && [ "$offline" -eq 0 ] \
           && probe_path_in_published_repo "$target"; then
        # Missing here, present in the repo this README is written to be read
        # on. Real case: README_EN.md was written straight into the public
        # repo, so the language switcher is live for every actual reader and
        # dead only in the private tree the file happens to sit in. Calling
        # that a dead link would be false, and a gate that cries false is a
        # gate nobody reads. Printed rather than silent — the two trees
        # having drifted is itself worth seeing.
        printf '  %s:%s  %s  → 本地没有，但 %s 上有（README 是写给那边的读者的）\n' \
          "$file" "$line" "$url" "$repo_slug" >> "$work/elsewhere.txt"
        local_ok=$((local_ok + 1))
      else
        printf '%s\t%s\t%s\t%s\n' "$file" "$line" "$url" "no such file: $target（在 ${repo_slug:-<无远端>} 上也没有）" >> "$work/fail.tsv"
      fi
      ;;
  esac
done < "$work/links.tsv"

# ── 3. HTTP checks ──────────────────────────────────────────────────────────
#
# Status code alone is not enough, and the links where it isn't enough are the
# dangerous ones. A TestFlight public link whose builds have all expired
# answers **HTTP 200** and renders "This beta isn't accepting any new testers
# right now" — from the reader's side that is every bit as dead as a 404, and
# it is the first thing a visitor taps. An App Store link for an app that
# isn't in the visitor's storefront answers 200 too, after quietly redirecting
# to the store's front page.
#
# So these hosts get a rule, and the rule is written as a POSITIVE assertion,
# fail-closed:
#
#   * `must_appear` — a regex that has to be in the rendered page. Absent =>
#     red. A denylist of Apple's current wording would have the opposite
#     failure mode: reword the page and the check goes silently green. Here
#     the only way to pass is for the page to actually still say the thing
#     that makes the link useful.
#   * `keep_token` — a regex pulled out of the ORIGINAL url whose match must
#     survive into the effective url after redirects. Catches "200, but it
#     bounced you somewhere else".
#
# Both are per-rule optional (`-` = not applicable).
# Format: <url-substring> TAB <must_appear|-> TAB <keep_token|-> TAB <why>
body_rules() {
  cat <<RULES
testflight.apple.com/join/	${LINK_CHECK_APP_NAME:-PendingBot|大绿豆}	-	页面上根本没出现 App 名字 —— beta 不收人 / 构建过期时 Apple 就回这种通用页（照样 200）。真开着的公开链接一定会写出 App 名字。名字变了就改 LINK_CHECK_APP_NAME
apps.apple.com/	-	(id[0-9]{6,})	链接被重定向走了，最终落点已经不含这个 App 的 id。多半是该 App 在**跑这次检查的这台机器所在的商店区域**不上架 —— 换个区域跑可能是绿的，判定前先看下面打印的最终 URL
RULES
}

# Strip tags/scripts so the assertion runs against what a reader actually sees.
render_body() {
  python3 - "$1" <<'PY'
import html, re, sys
try:
    s = open(sys.argv[1], encoding="utf-8", errors="replace").read()
except OSError:
    sys.exit(0)
s = re.sub(r"<script.*?</script>", " ", s, flags=re.S | re.I)
s = re.sub(r"<style.*?</style>", " ", s, flags=re.S | re.I)
s = html.unescape(re.sub(r"<[^>]+>", " ", s))
print(re.sub(r"\s+", " ", s).strip()[:20000])
PY
}

# HEAD first (cheap), then a ranged GET: plenty of hosts — Apple's among them —
# answer HEAD with 403/405 while the page itself is perfectly fine.
probe_url() {
  local file="$1" line="$2" url="$3" code body tmp
  local needle must_appear keep_token why
  local r_appear="" r_keep="" r_why="" matched=0 token effective

  while IFS=$'\t' read -r needle must_appear keep_token why; do
    [ -z "${needle:-}" ] && continue
    case "$url" in
      *"$needle"*) r_appear="$must_appear"; r_keep="$keep_token"; r_why="$why"; matched=1; break ;;
    esac
  done < <(body_rules)

  if [ "$matched" -eq 1 ]; then
    # This link needs its body and its landing URL, so go straight to a
    # full GET and record where the redirects ended up.
    tmp="$(mktemp)"
    code=$(curl -sS -o "$tmp" -w '%{http_code}' -L \
             --max-time "$TIMEOUT" --retry "$RETRIES" --retry-connrefused \
             -A "$UA" "$url" 2>/dev/null)
    effective=$(curl -sS -o /dev/null -w '%{url_effective}' -L \
             --max-time "$TIMEOUT" --retry "$RETRIES" --retry-connrefused \
             -A "$UA" "$url" 2>/dev/null)
    case "$code" in
      2*) ;;
      000) rm -f "$tmp"; printf 'FAIL\t%s\t%s\t%s\t%s\n' "$file" "$line" "$url" "no response (DNS / TLS / timeout)"; return ;;
      *)   rm -f "$tmp"; printf 'FAIL\t%s\t%s\t%s\t%s\n' "$file" "$line" "$url" "HTTP $code"; return ;;
    esac

    # (a) did the redirects carry us away from the thing we asked for?
    if [ "$r_keep" != "-" ] && [ -n "$r_keep" ]; then
      token=$(printf '%s' "$url" | grep -oE "$r_keep" | head -1)
      if [ -n "$token" ] && ! printf '%s' "$effective" | grep -qF "$token"; then
        rm -f "$tmp"
        printf 'FAIL\t%s\t%s\t%s\t%s\n' "$file" "$line" "$url" \
          "HTTP $code 但落点变了（$token 不在最终 URL 里）→ $effective —— $r_why"
        return
      fi
    fi

    # (b) does the page still say the thing that makes the link useful?
    if [ "$r_appear" != "-" ] && [ -n "$r_appear" ]; then
      body="$(render_body "$tmp")"
      if ! printf '%s' "$body" | grep -qiE "$r_appear"; then
        rm -f "$tmp"
        printf 'FAIL\t%s\t%s\t%s\t%s\n' "$file" "$line" "$url" \
          "HTTP $code 但正文里找不到 /$r_appear/ —— $r_why"
        return
      fi
    fi

    rm -f "$tmp"
    printf 'OK\t%s\t%s\t%s\t%s\n' "$file" "$line" "$url" "$code +内容断言"
    return
  fi

  code=$(curl -sS -o /dev/null -w '%{http_code}' -I -L \
           --max-time "$TIMEOUT" --retry "$RETRIES" --retry-connrefused \
           -A "$UA" "$url" 2>/dev/null)
  case "$code" in
    2*) printf 'OK\t%s\t%s\t%s\t%s\n' "$file" "$line" "$url" "$code"; return ;;
  esac

  code=$(curl -sS -o /dev/null -w '%{http_code}' -L \
           --max-time "$TIMEOUT" --retry "$RETRIES" --retry-connrefused \
           -A "$UA" -r 0-2047 "$url" 2>/dev/null)
  case "$code" in
    2*)  printf 'OK\t%s\t%s\t%s\t%s\n'   "$file" "$line" "$url" "$code" ;;
    000) printf 'FAIL\t%s\t%s\t%s\t%s\n' "$file" "$line" "$url" "no response (DNS / TLS / timeout)" ;;
    *)   printf 'FAIL\t%s\t%s\t%s\t%s\n' "$file" "$line" "$url" "HTTP $code" ;;
  esac
}
export -f probe_url body_rules render_body
export TIMEOUT RETRIES UA LINK_CHECK_APP_NAME

http_count=$(wc -l < "$work/http.tsv" | tr -d ' ')
http_ok=0
if [ "$http_count" -gt 0 ]; then
  tr '\t' '\n' < "$work/http.tsv" \
    | xargs -P "$JOBS" -n 3 bash -c 'probe_url "$0" "$1" "$2"' \
    > "$work/http-results.tsv" 2>/dev/null

  while IFS=$'\t' read -r status file line url detail; do
    [ "$status" = "OK" ] && continue
    printf '%s\t%s\t%s\t%s\n' "$file" "$line" "$url" "$detail" >> "$work/fail.tsv"
  done < "$work/http-results.tsv"

  http_ok=$(grep -c '^OK' "$work/http-results.tsv" 2>/dev/null | tr -d ' ')
  [ -z "$http_ok" ] && http_ok=0
fi

# ── 4. Known-broken registry ────────────────────────────────────────────────
# A gate that is red every single run stops being read, and then the first NEW
# dead link slips past unnoticed — the same failure as a gate that is blindly
# green, just wearing the opposite colour. So red is reserved for a dead link
# nobody has accounted for. A registered one still prints on every run, but as
# a warning, and only until its date.
: > "$work/known.tsv"
: > "$work/expired.tsv"
: > "$work/unregistered.tsv"
: > "$work/recovered.txt"
: > "$work/warn.txt"

if [ -n "$registry" ] && [ -f "$registry" ]; then
  while IFS=$'\t' read -r rlink rdate rowner rwhat; do
    case "${rlink:-}" in ''|'#'*) continue ;; esac
    if [ -z "${rdate:-}" ] || [ -z "${rowner:-}" ] || [ -z "${rwhat:-}" ]; then
      printf '%s\t%s\t%s\t%s\n' "$registry" "-" "$rlink" \
        "登记行不完整：必须是 链接<TAB>过期日<TAB>主人<TAB>在等什么" >> "$work/unregistered.tsv"
      continue
    fi
    printf '%s\t%s\t%s\t%s\n' "$rlink" "$rdate" "$rowner" "$rwhat" >> "$work/known.tsv"
  done < "$registry"
fi

while IFS=$'\t' read -r file line url detail; do
  [ -z "${url:-}" ] && continue
  hit="$(awk -F'\t' -v u="$url" '$1 == u { print; exit }' "$work/known.tsv")"
  if [ -z "$hit" ]; then
    printf '%s\t%s\t%s\t%s\n' "$file" "$line" "$url" "$detail" >> "$work/unregistered.tsv"
    continue
  fi
  rdate="$(printf '%s' "$hit" | cut -f2)"
  rowner="$(printf '%s' "$hit" | cut -f3)"
  rwhat="$(printf '%s' "$hit" | cut -f4)"
  # Plain string compare is correct here: both sides are zero-padded ISO dates.
  if [[ "$today" > "$rdate" ]]; then
    printf '%s\t%s\t%s\t%s\n' "$file" "$line" "$url" \
      "登记已于 $rdate 过期（等的是 $rowner：$rwhat）—— 要么它终于该修了，要么重新评估并改期" >> "$work/expired.tsv"
  else
    printf '  %s:%s  %s\n      → %s\n      等 %s（%s 前）：%s\n' \
      "$file" "$line" "$url" "$detail" "$rowner" "$rdate" "$rwhat" >> "$work/warn.txt"
  fi
done < "$work/fail.tsv"

# A registration that has outlived its reason is exactly the rot this file
# exists to avoid, so say so rather than letting it sit there forever.
while IFS=$'\t' read -r rlink rdate rowner rwhat; do
  [ -z "${rlink:-}" ] && continue
  if ! cut -f3 "$work/fail.tsv" | grep -qxF "$rlink"; then
    printf '  %s\n      → 这条已经好了（或已从文档里删掉）。把 %s 里这一行删掉。\n' \
      "$rlink" "$registry" >> "$work/recovered.txt"
  fi
done < "$work/known.tsv"

# ── 5. Report ───────────────────────────────────────────────────────────────
unreg_count=$(wc -l < "$work/unregistered.tsv" | tr -d ' ')
expired_count=$(wc -l < "$work/expired.tsv" | tr -d ' ')
fail_count=$(( unreg_count + expired_count ))
unchecked_count=$(wc -l < "$work/unchecked.txt" | tr -d ' ')
warn_count=$(grep -c '→' "$work/warn.txt" 2>/dev/null | tr -d ' ')
[ -z "$warn_count" ] && warn_count=0
recovered_count=$(grep -c '→' "$work/recovered.txt" 2>/dev/null | tr -d ' ')
[ -z "$recovered_count" ] && recovered_count=0

if [ "$unchecked_count" -gt 0 ]; then
  echo "UNCHECKED ($unchecked_count) — not a failure, but nobody verified these:"
  sed 's/^/  /' "$work/unchecked.txt"
  echo
fi

elsewhere_count=$(grep -c '→' "$work/elsewhere.txt" 2>/dev/null | tr -d ' ')
[ -z "$elsewhere_count" ] && elsewhere_count=0
if [ "$elsewhere_count" -gt 0 ]; then
  echo "RESOLVED ELSEWHERE ($elsewhere_count) — 本地树里没有，但在 README 真正的家里有："
  cat "$work/elsewhere.txt"
  echo
fi

if [ "$warn_count" -gt 0 ]; then
  echo "KNOWN BROKEN ($warn_count) — 登记在案、还没到期。不让 job 红，但每次都打出来："
  cat "$work/warn.txt"
  echo
fi

if [ "$recovered_count" -gt 0 ]; then
  echo "STALE REGISTRATIONS ($recovered_count) — 登记还在，问题没了："
  cat "$work/recovered.txt"
  echo
fi

echo "$((local_ok + http_ok)) ok  ·  $fail_count dead  ·  $warn_count known-broken  ·  $unchecked_count unchecked"

if [ "$fail_count" -gt 0 ]; then
  if [ "$expired_count" -gt 0 ]; then
    echo
    echo "EXPIRED REGISTRATIONS ($expired_count) — 「在等别人」只在一段时间内成立："
    while IFS=$'\t' read -r file line url detail; do
      printf '  %s:%s  %s\n      → %s\n' "$file" "$line" "$url" "$detail"
    done < "$work/expired.tsv"
  fi
  if [ "$unreg_count" -gt 0 ]; then
    echo
    echo "DEAD LINKS ($unreg_count) — 没人登记过的。这才是这道闸门的红："
    while IFS=$'\t' read -r file line url detail; do
      printf '  %s:%s  %s\n      → %s\n' "$file" "$line" "$url" "$detail"
    done < "$work/unregistered.tsv"
  fi
  echo
  echo "修掉它，或者删掉这个链接。自己修不了的登记进 $registry"
  echo "（一行：链接 <TAB> 过期日 <TAB> 主人 <TAB> 在等什么），到期自己变回红。"
  exit 1
fi

echo "all links good."
