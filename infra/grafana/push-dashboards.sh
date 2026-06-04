#!/usr/bin/env bash
# Push every dashboard JSON in ./dashboards to a Grafana instance via the API.
#
# WHY: Grafana Cloud cannot read local provisioning files (no filesystem under
# /etc/grafana/provisioning), so the committed YAML only works for self-hosted.
# This makes the repo the single source of truth for Cloud too: edit the JSON,
# run this, done. Do NOT hand-edit dashboards in the Grafana UI — changes here
# overwrite (overwrite:true), and UI edits would drift. If you must tweak in the
# UI, export the JSON back into ./dashboards to keep the repo canonical.
#
# Usage:
#   GRAFANA_URL=https://<org>.grafana.net \
#   GRAFANA_TOKEN=<service-account-token> \
#   GRAFANA_DS_UID=supabase_pendingbot_ro \
#   [GRAFANA_FOLDER_UID=<folder-uid>] \
#   infra/grafana/push-dashboards.sh
#
# Token: Grafana Cloud → Administration → Users and access → Service accounts →
#        add a service account (role: Editor) → add token. Keep it out of git.
# DS_UID: the uid of the PostgreSQL datasource you added (we suggested
#        `supabase_pendingbot_ro`). Find it under Connections → Data sources.
set -euo pipefail
: "${GRAFANA_URL:?set GRAFANA_URL, e.g. https://yourorg.grafana.net}"
: "${GRAFANA_TOKEN:?set GRAFANA_TOKEN (Grafana service-account token)}"
: "${GRAFANA_DS_UID:=supabase_pendingbot_ro}"
FOLDER_UID="${GRAFANA_FOLDER_UID:-}"

dir="$(cd "$(dirname "$0")/dashboards" && pwd)"
shopt -s nullglob
for f in "$dir"/*.json; do
  name="$(basename "$f")"
  payload="$(jq -n --slurpfile d "$f" --arg ds "$GRAFANA_DS_UID" --arg folder "$FOLDER_UID" '
    {
      dashboard: ($d[0] | .id = null),
      overwrite: true,
      inputs: [ { name: "DS_SUPABASE", type: "datasource", pluginId: "postgres", value: $ds } ]
    } + (if $folder != "" then { folderUid: $folder } else {} end)
  ')"
  printf "→ %-30s " "$name"
  curl -fsS -X POST "$GRAFANA_URL/api/dashboards/import" \
    -H "Authorization: Bearer $GRAFANA_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    | jq -r '"imported: \(.title)  (uid=\(.uid // "?"), v\(.version // "?"))"' \
    || { echo "FAILED — check GRAFANA_URL / token role (needs Editor) / DS uid"; exit 1; }
done
echo "Done. View at: $GRAFANA_URL/dashboards"
