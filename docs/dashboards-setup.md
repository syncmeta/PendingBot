# Dashboard stack — self-hosted setup runbook

> ⚠️ **降级为可选 fallback(2026-06-02)**:主方案已改为**零 VPS**——BI 用 Grafana Cloud Free 直连 Supabase、控制台用 Refine 部署 CF Pages(见 `docs/superpowers/specs/2026-06-01-dashboard-stack-design.md`)。本 runbook(自托管 Metabase+Appsmith on VPS)**仅在将来确实需要点选式自助 BI 且愿意养 VPS 时**才用。`bi_ro` 只读角色已建,现给 Grafana 用。

Stand up the **self-hosted** half of the PendingBot dashboard stack on a single
VPS: **Metabase** (read-only BI on Supabase) + **Appsmith** (admin/moderation
console, writes via edge). The SaaS half (PostHog / Langfuse / Sentry) is
configured in their own dashboards and is out of scope here.

Design reference: `docs/superpowers/specs/2026-06-01-dashboard-stack-design.md`
and the dashboard-stack memory. Three "anti-fragility" principles drive this:
**read it directly from Postgres instead of building a pipeline**, **separate
read (read-only) from write (via edge)**, and **keep each block independently
replaceable** (hence: no managed-host lock-in, plain Docker Compose, backups to
R2 so the whole thing can move VPS in an afternoon).

Infra files:
- `infra/dashboards/docker-compose.yml`
- `infra/dashboards/.env.example`
- `supabase/migrations/<ts>_metabase_readonly_role.sql` (the `bi_ro` role)

---

## 0. Prerequisites

- A Cloudflare R2 bucket + S3 API token (for backups).
- DNS you control (suggested: `metrics.pendingname.com`, `admin.pendingname.com`).
- The `bi_ro` migration applied to Supabase (see step 5).

---

## 1. Provision the VPS (Hetzner Cloud)

1. Create a server: **CX32 / CPX31 class, 8 GB RAM** (4 GB OOMs once Metabase's
   JVM + Appsmith's bundled Mongo/Redis are both warm), Ubuntu 24.04 LTS, in an
   EU region (privacy posture — keep analytics infra in the EU).
2. Add your SSH key during creation. Do **not** enable password SSH.
3. Note the public IPv4.

---

## 2. Base hardening

SSH in as root, then:

```bash
adduser deploy && usermod -aG sudo deploy
rsync --archive --chown=deploy:deploy ~/.ssh /home/deploy
# Disable root + password SSH:
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart ssh
```

Reconnect as `deploy` from here on.

---

## 3. Firewall — limit the source

Two layers. Use Hetzner Cloud Firewall (at the network edge) **and** ufw on the
box.

**Hetzner Cloud Firewall** (web console): inbound allow only
- SSH (22) from your home/office IP(s) only.
- HTTPS (443) from anywhere (for the reverse proxy).
- Everything else: deny.

**On the box:**

```bash
sudo apt-get update && sudo apt-get install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from <YOUR_IP> to any port 22 proto tcp
sudo ufw allow 443/tcp
sudo ufw enable
```

The Metabase (3000) and Appsmith (8080) ports are bound to `127.0.0.1` in the
compose file, so they are never directly reachable — only the reverse proxy on
443 fronts them.

---

## 4. Install Docker

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker deploy   # re-login for group to apply
docker compose version           # sanity
```

---

## 5. Apply the Supabase read-only role

From your **local main worktree** (where `supabase/.temp/linked-project.json`
lives):

```bash
supabase db push --linked
bun --filter='@pendingbot/edge' run types:db   # regen schema.ts
```

Then set the role password out-of-band (NOT in the migration):

```bash
supabase db query --linked \
  "ALTER ROLE bi_ro WITH PASSWORD '$(openssl rand -base64 32)';"
```

Capture that password — it goes into `MB_DB_SUPABASE_PASS` in `.env`. The role
can only `SELECT` on schema `pendingbot`; new tables are auto-readable via
`ALTER DEFAULT PRIVILEGES`.

---

## 6. Deploy the stack

```bash
mkdir -p ~/dashboards && cd ~/dashboards
# Copy infra/dashboards/docker-compose.yml and .env.example here
#   scp infra/dashboards/{docker-compose.yml,.env.example} deploy@<ip>:~/dashboards/
cp .env.example .env
```

Fill `.env` — generate every secret freshly:

```bash
openssl rand -base64 32   # MB_METADATA_DB_PASSWORD
openssl rand -base64 32   # MB_ENCRYPTION_SECRET_KEY
openssl rand -base64 24   # APPSMITH_ENCRYPTION_PASSWORD
openssl rand -base64 24   # APPSMITH_ENCRYPTION_SALT
```

Also set the `MB_DB_SUPABASE_*`, `APPSMITH_CUSTOM_DOMAIN`, and `R2_*` values.

Bring it up:

```bash
docker compose --env-file .env up -d
docker compose ps          # all healthy?
docker compose logs -f metabase   # first boot migrates its metadata DB
```

---

## 7. Reverse proxy + TLS

Put Caddy in front (simplest auto-TLS). Example `~/dashboards/Caddyfile`:

```
metrics.pendingname.com {
    reverse_proxy 127.0.0.1:3000
}
admin.pendingname.com {
    reverse_proxy 127.0.0.1:8080
}
```

Run Caddy (host package or a sidecar container) and point DNS A-records at the
VPS. Caddy fetches Let's Encrypt certs automatically.

---

## 8. Wire Metabase to Supabase (read-only)

1. Open `https://metrics.pendingname.com`, create the admin account, enable 2FA
   under **Settings → Authentication** (Google Authenticator TOTP).
2. **Admin → Databases → Add database → PostgreSQL**, using the
   `MB_DB_SUPABASE_*` values from `.env`:
   - Host: `db.<project-ref>.supabase.co` (direct) or
     `aws-0-<region>.pooler.supabase.com` (session pooler, port 5432; then
     username is `bi_ro.<project-ref>`).
   - Database `postgres`, user `bi_ro`, the password from step 5.
   - **Schemas: only `pendingbot`.** SSL required.
3. Build the revenue / wallet questions off `billing_ledger`, `billing_config`,
   `wallets`, etc. **Never use Metabase Actions** — the role can't write anyway,
   but keep the discipline.

---

## 9. Wire Appsmith to edge (writes)

1. Open `https://admin.pendingname.com`, create the admin account, enable the
   built-in 2FA, and restrict signups (Admin Settings → disable public signup).
2. Add an **Authenticated API** datasource pointing at `APPSMITH_EDGE_API_BASE`
   (the deployed worker). All admin grants / billing adjustments / moderation
   actions call edge endpoints — Appsmith never touches Postgres directly, so
   every write is audited server-side.

---

## 10. Backups to R2 (cron)

Back up the two stateful volumes: Metabase's metadata Postgres and Appsmith's
stack dir. The Supabase BI data is **not** backed up here (Supabase owns that).

Create `~/dashboards/backup.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
set -a; source .env; set +a

STAMP=$(date -u +%Y%m%d-%H%M%S)
TMP=$(mktemp -d)

# 1. Metabase metadata Postgres → compressed dump
docker compose exec -T metabase-db \
  pg_dump -U metabase -d metabase --no-owner --clean \
  | gzip > "$TMP/metabase-metadata-$STAMP.sql.gz"

# 2. Appsmith stack volume → tarball
docker run --rm \
  -v dashboards_appsmith-stacks:/data:ro \
  -v "$TMP":/backup alpine \
  tar czf "/backup/appsmith-stacks-$STAMP.tar.gz" -C /data .

# 3. Upload to R2 (S3-compatible) via the aws CLI
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
ENDPOINT="https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com"
aws s3 cp "$TMP/" "s3://$R2_BUCKET/dashboards/" --recursive \
  --endpoint-url "$ENDPOINT"

rm -rf "$TMP"
```

> The volume name is `<compose-project>_appsmith-stacks`. The compose project
> defaults to the directory name (`dashboards`); confirm with `docker volume ls`.

Install prerequisites and schedule daily at 03:00 UTC:

```bash
sudo apt-get install -y awscli
chmod +x ~/dashboards/backup.sh
( crontab -l 2>/dev/null; \
  echo "0 3 * * * /home/deploy/dashboards/backup.sh >> /home/deploy/dashboards/backup.log 2>&1" ) \
  | crontab -
```

Set a bucket lifecycle rule in R2 to expire `dashboards/` objects after ~30 days
so backups don't accumulate forever.

---

## 11. Portability — move to another VPS

Because all durable state is in two volumes + a portable `.env`, migration is
mechanical (the "可移植纪律" from the spec):

1. Stand up the new VPS through steps 1–4 and 7.
2. Copy `docker-compose.yml` and the **same** `.env` (the encryption keys MUST
   match or Metabase/Appsmith can't decrypt saved datasource secrets).
3. Pull the latest backup from R2:
   ```bash
   aws s3 cp s3://$R2_BUCKET/dashboards/ ./restore/ --recursive \
     --endpoint-url "https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com"
   ```
4. Start only the metadata DB, restore the dump, then bring up the rest:
   ```bash
   docker compose --env-file .env up -d metabase-db
   gunzip -c restore/metabase-metadata-*.sql.gz \
     | docker compose exec -T metabase-db psql -U metabase -d metabase
   # Restore Appsmith stack volume before first appsmith start:
   docker run --rm -v dashboards_appsmith-stacks:/data \
     -v "$PWD/restore":/backup alpine \
     sh -c "cd /data && tar xzf /backup/appsmith-stacks-*.tar.gz"
   docker compose --env-file .env up -d
   ```
5. Repoint DNS A-records at the new IP. The `bi_ro` Supabase role is
   unchanged, so BI reconnects with no DB-side work.

---

## Security checklist

- [ ] Metabase uses `bi_ro` (SELECT-only) — verified it cannot write.
- [ ] Both 3000/8080 bound to `127.0.0.1`; only 443 (proxy) + scoped SSH open.
- [ ] Hetzner + ufw firewalls both active; SSH source-restricted.
- [ ] Admin accounts on both tools have strong passwords + 2FA; public signup off.
- [ ] All secrets generated with `openssl rand`, stored only in `.env`.
- [ ] Daily backup cron green; a restore has been test-run at least once.
