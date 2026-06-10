#!/usr/bin/env bash
# Push every Worker secret for an env in one go. Reads non-sensitive values
# from apps/edge/.dev.vars; reads APNS .p8 contents from local file paths
# you point at. Nothing is logged to stdout — values pipe straight into
# `wrangler secret put`.
#
# Usage:  ./scripts/push-secrets.sh
# Pre-launch we only have one deployed env (`production` in wrangler.jsonc);
# add an env arg back here when a second env is introduced.
set -euo pipefail

ENV="production"

cd "$(dirname "$0")/.."   # apps/edge

# --- inputs ------------------------------------------------------------------
# Sensitive infrastructure identifiers (Apple Team ID, APNs Key IDs, .p8 file
# paths) live in .secrets.local — git-ignored, sourced here. Copy
# .secrets.local.example, fill in, and re-run.
DEV_VARS=".dev.vars"
SECRETS_LOCAL="scripts/.secrets.local"

[ -f "$DEV_VARS" ] || { echo ".dev.vars not found at $DEV_VARS" >&2; exit 1; }
[ -f "$SECRETS_LOCAL" ] || {
  echo "missing $SECRETS_LOCAL — copy scripts/.secrets.local.example and fill it in" >&2
  exit 1
}
# shellcheck disable=SC1090
. "$SECRETS_LOCAL"

: "${APNS_TEAM_ID:?APNS_TEAM_ID not set in $SECRETS_LOCAL}"
: "${APNS_TOPIC:?APNS_TOPIC not set in $SECRETS_LOCAL}"
: "${APNS_KEY_ID_DEV:?APNS_KEY_ID_DEV not set in $SECRETS_LOCAL}"
: "${APNS_KEY_ID_PROD:?APNS_KEY_ID_PROD not set in $SECRETS_LOCAL}"
: "${APNS_KEY_DEV_FILE:?APNS_KEY_DEV_FILE not set in $SECRETS_LOCAL}"
: "${APNS_KEY_PROD_FILE:?APNS_KEY_PROD_FILE not set in $SECRETS_LOCAL}"

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
# SUPABASE_PUBLISHABLE_KEY is NOT here — it's public, lives as a plain var
# in wrangler.jsonc. Only the sb_secret_… key is a real secret.
put SUPABASE_SECRET_KEY       "$(get_var SUPABASE_SECRET_KEY)"
put OPENROUTER_API_KEY        "$(get_var OPENROUTER_API_KEY)"
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
