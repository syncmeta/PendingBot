# Grafana — PendingBot revenue / wallet BI (block 5 of the dashboard stack)

Checked-in Grafana provisioning + dashboard JSON for the read-only revenue / wallet
dashboards, pointing at Supabase Postgres (schema `pendingbot`) via a SELECT-only role.

```
infra/grafana/
├── README.md                                   ← this file
├── provisioning/
│   ├── datasources/
│   │   └── supabase-postgres.yaml              ← Postgres datasource (metabase_ro)
│   └── dashboards/
│       └── pendingbot-revenue.yaml             ← file provider (self-hosted only)
└── dashboards/
    ├── 01-revenue.json                         ← topups / refunds / net / refund rate
    ├── 02-wallet-quota.json                    ← balances + overdraft list
    ├── 03-group-pool.json                      ← group pool (实缴池) + pledge usage (认缴)
    ├── 04-cost-by-category.json                ← consumption by task_type / model / entry_type
    └── 05-conversion-funnel.json               ← registrations → bot → group → paid
```

## Versions targeted (confirmed from official docs)

| Thing | Value | Source |
|---|---|---|
| Provisioning file `apiVersion` | `1` (datasources + dashboards) | [Provisioning docs](https://grafana.com/docs/grafana/latest/administration/provisioning/) |
| Dashboard JSON `schemaVersion` | **41** (Grafana 12 / latest) | [Dashboard HTTP API examples](https://grafana.com/docs/grafana/latest/developer-resources/api-reference/http-api/dashboard/) |
| Postgres datasource `type` | `postgres`, `database` in `jsonData`, password in `secureJsonData` | [Postgres configure](https://grafana.com/docs/grafana/latest/datasources/postgres/configure/) |
| Datasource ref in panels/targets | `{ "type": "postgres", "uid": "${DS_SUPABASE}" }` | Standard export-for-sharing form ([JSON model](https://grafana.com/docs/grafana/latest/dashboards/build-dashboards/view-dashboard-json-model/)) |
| Postgres SQL target | `rawSql` + `format: time_series`\|`table` + `refId` + `editorMode: code`; time series needs a column aliased `time` and `$__timeGroup` / `$__timeFilter` macros | [Postgres query editor](https://grafana.com/docs/grafana/latest/datasources/postgres/query-editor/) |

The dashboard JSONs use the `__inputs` / `${DS_SUPABASE}` datasource-**variable** form (the
form Grafana produces with "Export for sharing externally"). That's what makes them portable:
on import you pick the real datasource and Grafana substitutes the uid. Self-hosted file
provisioning resolves the same variable from the provider.

> **Note on file format:** Grafana provisioning *configs* (datasource + dashboard provider)
> are **YAML** by spec — there is no JSON variant. Only the dashboard *models* are JSON.
> The two `.yaml` files follow `apiVersion: 1` exactly as documented.

## Import into Grafana Cloud (the realistic path)

### Automated push (recommended over clicking — repo stays source of truth)

`infra/grafana/push-dashboards.sh` pushes all five dashboard JSONs via the
Grafana API in one shot (idempotent — `overwrite:true`, resolves the
`${DS_SUPABASE}` input to your datasource uid). Use this instead of importing
one-by-one, and re-run it whenever you edit a dashboard JSON:

```sh
GRAFANA_URL=https://<org>.grafana.net \
GRAFANA_TOKEN=<service-account-token> \
GRAFANA_DS_UID=supabase_pendingbot_ro \
infra/grafana/push-dashboards.sh
```

Token: Grafana Cloud → Administration → Users and access → Service accounts →
new account (role **Editor**) → add token. **Source-of-truth discipline:** the
repo JSON is canonical; don't hand-edit in the Grafana UI (this script
overwrites). If you do tweak in the UI, export the JSON back into `dashboards/`.

> Heavier IaC alternatives (if you outgrow the script): the Grafana Terraform
> provider (`grafana_dashboard`/`grafana_data_source`) or `grizzly` — both take
> the same JSON. Overkill for five dashboards, noted for later.


Grafana **Cloud cannot read local provisioning files** — there's no filesystem you control
under `/etc/grafana/provisioning`. So the `provisioning/*.yaml` files are the source of truth
for a **self-hosted** Grafana (or for replication via Terraform / grizzly), and Cloud uses
manual / API import:

### 1. Add the datasource (once)
Cloud UI → **Connections → Data sources → Add data source → PostgreSQL**, then fill in the
values from `provisioning/datasources/supabase-postgres.yaml`:
- Host: `<supabase-db-host>:<port>` (session pooler / connection pooler host, port 5432)
- Database: `postgres`
- User: `metabase_ro`
- Password: the `metabase_ro` password (kept out of git)
- TLS/SSL Mode: `require`

Give it the **uid `supabase_pendingbot_ro`** if the UI lets you set one, or just note the
generated uid — you'll select this datasource during dashboard import either way.

*(Infra-as-code alternative: the `grafana_data_source` Terraform resource or grizzly, fed the
same field values. Cloud supports both; the committed YAML maps 1:1 to those fields.)*

### 2. Import each dashboard
Cloud UI → **Dashboards → New → Import** →
- **Upload JSON file** (or paste the contents of) each `dashboards/0X-*.json`
- When prompted for the `DS_SUPABASE` input, pick the PostgreSQL datasource from step 1
- Click **Import**

API alternative (legacy create endpoint, still supported):
`POST /api/dashboards/db` with body `{ "dashboard": <the JSON model with id:null>, "folderUid": "...", "overwrite": true }`.

## Datasource setup details

- **Role:** `metabase_ro` — a SELECT-only Postgres role (name reused from the Metabase era).
- **Host / password:** never committed. Self-hosted provisioning reads `${SUPABASE_DB_HOST}`,
  `${SUPABASE_DB_PORT}`, `${SUPABASE_DB_PASSWORD}` from Grafana's process env. Cloud takes them
  via the UI.
- **IP allowlist / network:** Supabase's direct Postgres endpoint may sit behind network
  restrictions. For Grafana Cloud you generally need either Supabase's **connection pooler**
  reachable from the public internet, or **Grafana Private Data source Connect (PDC)** to tunnel
  to a private endpoint. Confirm Supabase network settings allow Grafana Cloud's egress, or set
  up PDC, before the datasource will connect.

## Alerting (refund-rate panel + overdraft panel)

Two panels are built to be alert sources:
- `01-revenue.json` → **"Refund rate (alert candidate)"** (panel id 4)
- `02-wallet-quota.json` → **"Overdrawn wallets (balance < 0)"** (panel id 3)
- `03-group-pool.json` → **"Pledge usage rate (认缴使用率)"** (panel id 3)

Grafana Cloud alerting is configured in the UI (not provisioned by these files). To wire it:
1. **Alerting → Alert rules → New alert rule**.
2. Query: reuse the panel's SQL against the `supabase_pendingbot_ro` datasource (it must return
   a single numeric value — these panels already reduce to one row).
3. Expression: `WHEN last() OF A IS ABOVE 0.1` (refund rate 10%) / `IS ABOVE 0` (overdrawn count).
4. Set evaluation interval + contact point.

> Note: Grafana SQL-backed (data source–managed) alert rules require the datasource to support
> backend alerting; the Postgres data source does. If you prefer fully-as-code alerts, use the
> Terraform `grafana_rule_group` resource — out of scope for this block, documented here for the
> user to wire in the UI.

---

## Panel → source table/column audit

Every SQL target below references **only** columns verified against
`apps/edge/src/db/schema.ts` and `supabase/migrations/0033_billing.sql`. No invented columns.

### 01-revenue.json — `pendingbot.topups`, `pendingbot.billing_ledger`
- `topups`: `paid_amount_minor` (bigint minor units), `paid_currency`, `status`
  (`pending|verified|failed|refunded`), `channel`
  (`apple_iap|stripe|redemption|admin_grant|signup_bonus|adjust`), `credits_granted`,
  `is_sandbox`, `created_at`.
- `billing_ledger`: `entry_type` (`topup|grant|redemption|refund|adjust|signup_bonus`),
  `delta_credits` (bigint), `created_at`.
- Net revenue = SUM(verified) − SUM(refunded) over `paid_amount_minor`. Refund rate = same ratio.

### 02-wallet-quota.json — `pendingbot.subject_wallets`, `pendingbot.subjects`
- `subject_wallets`: `balance_credits`, `lifetime_topup_credits`, `lifetime_spent_credits`,
  `balance_updated_at`, `subject_id`.
- `subjects`: `id`, `display_name`, `subject_type`, `kind`.
- Overdraft list = wallets where `balance_credits < 0`.

### 03-group-pool.json — `pendingbot.subject_wallets` + `pendingbot.subjects` + `pendingbot.group_member_billing` + `pendingbot.conversations`
- 实缴池 (funded pool) = SUM(`subject_wallets.balance_credits`) for `subjects.subject_type = 'group'`.
- 认缴 (pledged caps) = SUM(`group_member_billing.cap_credits`) where `participates` and cap not NULL.
- `group_member_billing`: `cap_credits` (nullable), `spent_credits`, `overdrawn`, `participates`,
  `conversation_id`, `user_id`.
- `conversations.title` for the group label.

### 04-cost-by-category.json — `pendingbot.audit_log`, `pendingbot.billing_ledger`
- `audit_log` (the real per-call consumption table): `task_type` (category), `model_id`,
  `cost_credits`, `cost_usd`, `tool_cost_usd`, `input_tokens`, `output_tokens`, `total_tokens`,
  `created_at`.
- `billing_ledger`: `entry_type`, `delta_credits`, `created_at`.

### 05-conversion-funnel.json — `users`, `bots`, `group_join_requests`, `topups`
- `users`: `id`, `created_at` (stage 1 registrations).
- `bots`: `creator_id`, `created_at` (stage 2, distinct creators).
- `group_join_requests`: `requester_id`, `status` (`pending|approved|rejected|expired`),
  `decided_at`, `created_at` (stage 3, approved).
- `topups`: `user_id`, `status`, `channel`, `is_sandbox`, `created_at` (stage 4, verified
  real-money: `channel IN ('apple_iap','stripe')`).

## Columns / tables we could NOT confirm (gaps — not silently guessed)

1. **No `pnc_ledger` table.** The brief named `pnc_ledger`; the real wallet ledger in this
   schema is **`billing_ledger`** (cols: `actor_user_id, created_at, delta_credits, entry_type,
   id, metadata, reason, redemption_id, topup_id, user_id`). All panels use `billing_ledger`.
2. **No Polar audit table.** No `polar*` table or column exists in `schema.ts`. Revenue panels
   therefore derive fiat from `topups.paid_amount_minor` only. If/when a Polar
   order/transaction table lands, add a Polar-vs-internal reconciliation panel.
3. **No dedicated pledge / pool table.** There is no `*_pledge` or `group_pool` table. The
   group-pool dashboard reconstructs 实缴池 from group-subject wallets and 认缴 from
   `group_member_billing.cap_credits`. If a formal pledge ledger is added later, repoint panel 03.
4. **Multi-currency:** `topups.paid_currency` exists but panels sum `paid_amount_minor` as if
   single-currency (labeled USD). If multiple `paid_currency` values appear, the revenue sums
   are **not** FX-normalised — add a per-currency breakdown or an FX step before trusting totals.
5. **`audit_log` vs `billing_ledger` for "consumption":** `billing_ledger.entry_type` has no
   `consume`/`debit` value (enum is issue-side only). Actual per-call spend is in `audit_log`
   (`cost_credits`), so the cost-by-category dashboard uses `audit_log` as primary.

## Preconditions the user must do before these work

- [ ] **Create the `metabase_ro` SELECT-only role** + grant `USAGE` on schema `pendingbot` and
  `SELECT` on the tables above. **No migration named `*metabase_readonly_role*` exists in this
  worktree** — this role is a prerequisite and must be applied separately (own migration or
  manual SQL). Until then the datasource cannot connect.
- [ ] **Set the datasource password / host** (Cloud UI, or `SUPABASE_DB_*` env for self-hosted).
- [ ] **Network reachability:** ensure Supabase's pooler is reachable from Grafana Cloud egress,
  or set up Grafana **PDC**; check Supabase IP allowlist / network restrictions.
