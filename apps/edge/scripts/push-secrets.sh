#!/usr/bin/env bash
# Push every Worker secret for an env in one go. Reads non-sensitive values
# from apps/edge/.dev.vars; reads APNS .p8 contents from local file paths
# you point at. Nothing is logged to stdout — values pipe straight into
# `wrangler secret put`.
#
# Usage:  ./scripts/push-secrets.sh production
#         ./scripts/push-secrets.sh staging
set -euo pipefail

ENV="${1:-production}"
case "$ENV" in
  production|staging) ;;
  *) echo "usage: $0 production|staging" >&2; exit 1 ;;
esac

cd "$(dirname "$0")/.."   # apps/edge

# --- inputs ------------------------------------------------------------------
DEV_VARS=".dev.vars"
APNS_KEY_DEV_FILE="${APNS_KEY_DEV_FILE:-/Users/hey/Documents/AuthKey_534U267MGS.p8}"
APNS_KEY_PROD_FILE="${APNS_KEY_PROD_FILE:-/Users/hey/Documents/AuthKey_92G9Z8CP7N.p8}"
APNS_TEAM_ID="${APNS_TEAM_ID:-M42BKJN82S}"
APNS_TOPIC="${APNS_TOPIC:-com.pendingname.pendingbot}"
APNS_KEY_ID_DEV="${APNS_KEY_ID_DEV:-534U267MGS}"
APNS_KEY_ID_PROD="${APNS_KEY_ID_PROD:-92G9Z8CP7N}"

[ -f "$DEV_VARS" ] || { echo ".dev.vars not found at $DEV_VARS" >&2; exit 1; }
[ -f "$APNS_KEY_DEV_FILE" ] || { echo "missing $APNS_KEY_DEV_FILE" >&2; exit 1; }
[ -f "$APNS_KEY_PROD_FILE" ] || { echo "missing $APNS_KEY_PROD_FILE" >&2; exit 1; }

# Pull a KEY=VALUE line out of .dev.vars (strips quotes if present).
get_var() {
  local name="$1"
  local line
  line=$(grep -E "^${name}=" "$DEV_VARS" | head -1) || return 1
  echo "${line#${name}=}" | sed 's/^"\(.*\)"$/\1/'
}

put() {
  local name="$1"
  local value="$2"
  if [ -z "$value" ]; then
    echo "skip $name (empty)" >&2
    return
  fi
  printf "  → %-28s" "$name"
  printf '%s' "$value" | ./node_modules/.bin/wrangler secret put "$name" --env "$ENV" >/dev/null 2>&1 \
    && echo " ok" || echo " FAILED"
}

WRANGLER=./node_modules/.bin/wrangler
[ -x "$WRANGLER" ] || { echo "wrangler not built — run \`bun install\`" >&2; exit 1; }

echo "Pushing secrets to env=$ENV …"

# --- from .dev.vars ----------------------------------------------------------
put SUPABASE_ANON_KEY         "$(get_var SUPABASE_ANON_KEY)"
put SUPABASE_SERVICE_ROLE_KEY "$(get_var SUPABASE_SERVICE_ROLE_KEY)"
put OPENROUTER_API_KEY        "$(get_var OPENROUTER_API_KEY)"
put DAYTONA_API_KEY           "$(get_var DAYTONA_API_KEY)"
put DAYTONA_API_URL           "$(get_var DAYTONA_API_URL)"
put HONCHO_API_KEY            "$(get_var HONCHO_API_KEY)"
put HONCHO_WORKSPACE_ID       "$(get_var HONCHO_WORKSPACE_ID)"
put JINA_API_KEY              "$(get_var JINA_API_KEY)"

# --- APNS metadata + .p8 contents -------------------------------------------
put APNS_TEAM_ID       "$APNS_TEAM_ID"
put APNS_TOPIC         "$APNS_TOPIC"
put APNS_KEY_ID_DEV    "$APNS_KEY_ID_DEV"
put APNS_KEY_ID_PROD   "$APNS_KEY_ID_PROD"
put APNS_KEY_DEV       "$(cat "$APNS_KEY_DEV_FILE")"
put APNS_KEY_PROD      "$(cat "$APNS_KEY_PROD_FILE")"

echo "Done."
