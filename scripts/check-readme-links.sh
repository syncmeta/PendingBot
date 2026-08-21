#!/usr/bin/env bash
# Check every link in the reader-facing markdown (README / README_EN /
# CONTRIBUTING / SECURITY) and fail if any of them is dead.
#
# Why this exists: the release checklist used to say "click every link before
# publishing". Anything that depends on a person remembering eventually gets
# skipped — and a dead link on the front page of a public repo is the first
# thing a visitor hits. So the check is a machine's job.
#
# What it checks, by link kind:
#
#   https://…        HTTP request. Anything that isn't 2xx is a failure.
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
#   scripts/check-readme-links.sh README.md …         # explicit files
#   scripts/check-readme-links.sh --offline           # skip HTTP, local only
#   scripts/check-readme-links.sh --repo owner/name   # resolve ../../ links
#
# Exit codes: 0 all good · 1 at least one dead link · 2 bad usage.

set -uo pipefail

TIMEOUT="${LINK_CHECK_TIMEOUT:-20}"
RETRIES="${LINK_CHECK_RETRIES:-2}"
JOBS="${LINK_CHECK_JOBS:-8}"
UA="${LINK_CHECK_UA:-Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36}"

offline=0
repo_slug="${LINK_CHECK_REPO:-}"
files=()

while [ $# -gt 0 ]; do
  case "$1" in
    --offline) offline=1; shift ;;
    --repo) repo_slug="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) files+=("$1"); shift ;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 2

if [ ${#files[@]} -eq 0 ]; then
  for f in README.md README_EN.md CONTRIBUTING.md SECURITY.md; do
    [ -f "$f" ] && files+=("$f")
  done
fi
if [ ${#files[@]} -eq 0 ]; then
  echo "no reader-facing markdown found — nothing to check" >&2
  exit 2
fi

# Derive owner/name from the origin remote so GitHub-relative links
# (../../releases, ../../issues, ../../security/advisories/new) can actually
# be requested. A repo with no remote yet — e.g. a freshly prepared public
# snapshot — reports them as UNCHECKED instead of guessing.
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
: > "$work/fail.txt"
: > "$work/unchecked.txt"
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
        printf '%s:%s  %s  → no heading with that anchor in %s\n' "$file" "$line" "$url" "$file" >> "$work/fail.txt"
      fi
      ;;
    ../../*)
      if [ -n "$repo_slug" ] && [ "$offline" -eq 0 ]; then
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
        local_ok=$((local_ok + 1))
      else
        printf '%s:%s  %s  → no such file: %s\n' "$file" "$line" "$url" "$target" >> "$work/fail.txt"
      fi
      ;;
  esac
done < "$work/links.tsv"

# ── 3. HTTP checks ──────────────────────────────────────────────────────────
#
# Status code alone is not enough for every link. A TestFlight public link
# whose builds have all expired answers **HTTP 200** and renders "This beta
# isn't accepting any new testers right now" — from the reader's side that is
# every bit as dead as a 404, and it is exactly the link a first-time visitor
# taps. So some hosts get a body assertion on top of the status check.
#
# Add a rule as: <url-substring> <TAB> <case-insensitive regex that must NOT
# appear in the rendered body> <TAB> <what to tell the human>
body_rules() {
  cat <<'RULES'
testflight.apple.com/join/	isn.t accepting any new testers|beta (is|was) full|no longer accepting|this beta has ended	TestFlight 链接活着但这个 beta 不收人了（构建过期或名额满）
apps.apple.com/	app is (currently )?not available|not available in your country	App Store 页面在该区域不可用
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
  local file="$1" line="$2" url="$3" code rule pattern why body tmp

  rule=""
  while IFS=$'\t' read -r needle pattern why; do
    case "$url" in *"$needle"*) rule="$pattern"$'\t'"$why"; break ;; esac
  done < <(body_rules)

  if [ -n "$rule" ]; then
    # This link needs its body read, so go straight to a full GET.
    tmp="$(mktemp)"
    code=$(curl -sS -o "$tmp" -w '%{http_code}' -L \
             --max-time "$TIMEOUT" --retry "$RETRIES" --retry-connrefused \
             -A "$UA" "$url" 2>/dev/null)
    case "$code" in
      2*) ;;
      000) rm -f "$tmp"; printf 'FAIL\t%s\t%s\t%s\t%s\n' "$file" "$line" "$url" "no response (DNS / TLS / timeout)"; return ;;
      *)   rm -f "$tmp"; printf 'FAIL\t%s\t%s\t%s\t%s\n' "$file" "$line" "$url" "HTTP $code"; return ;;
    esac
    pattern="${rule%%$'\t'*}"
    why="${rule#*$'\t'}"
    body="$(render_body "$tmp")"
    rm -f "$tmp"
    if printf '%s' "$body" | grep -qiE "$pattern"; then
      printf 'FAIL\t%s\t%s\t%s\t%s\n' "$file" "$line" "$url" "HTTP $code 但页面内容是死的 —— $why"
    else
      printf 'OK\t%s\t%s\t%s\t%s\n' "$file" "$line" "$url" "$code +body"
    fi
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
export TIMEOUT RETRIES UA

http_count=$(wc -l < "$work/http.tsv" | tr -d ' ')
http_ok=0
if [ "$http_count" -gt 0 ]; then
  tr '\t' '\n' < "$work/http.tsv" \
    | xargs -P "$JOBS" -n 3 bash -c 'probe_url "$0" "$1" "$2"' \
    > "$work/http-results.tsv" 2>/dev/null

  while IFS=$'\t' read -r status file line url detail; do
    [ "$status" = "OK" ] && continue
    printf '%s:%s  %s  → %s\n' "$file" "$line" "$url" "$detail" >> "$work/fail.txt"
  done < "$work/http-results.tsv"

  http_ok=$(grep -c '^OK' "$work/http-results.tsv" 2>/dev/null | tr -d ' ')
  [ -z "$http_ok" ] && http_ok=0
fi

# ── 4. Report ───────────────────────────────────────────────────────────────
fail_count=$(wc -l < "$work/fail.txt" | tr -d ' ')
unchecked_count=$(wc -l < "$work/unchecked.txt" | tr -d ' ')

if [ "$unchecked_count" -gt 0 ]; then
  echo "UNCHECKED ($unchecked_count) — not a failure, but nobody verified these:"
  sed 's/^/  /' "$work/unchecked.txt"
  echo
fi

echo "$((local_ok + http_ok)) ok  ·  $fail_count dead  ·  $unchecked_count unchecked"

if [ "$fail_count" -gt 0 ]; then
  echo
  echo "DEAD LINKS:"
  sort "$work/fail.txt" | sed 's/^/  /'
  echo
  echo "Fix them, or remove the link. A dead link on the front page is the"
  echo "first thing a visitor hits."
  exit 1
fi

echo "all links good."
