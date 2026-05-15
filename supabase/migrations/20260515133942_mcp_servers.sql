-- 20260515133942_mcp_servers.sql
--
-- Registry of upstream MCP servers the edge worker can connect to.
-- Until now the worker spoke to Exa via hardcoded URL + env var; this
-- table is what backs the board "MCP servers" admin page so adding a
-- new connector is a table insert + a `wrangler secret put` rather
-- than a code change + deploy.
--
-- Secret values stay in Cloudflare Workers Secrets — only the env-var
-- *name* lives here in `secret_ref`. The worker resolves the actual
-- header value at request time via env[secret_ref].

BEGIN;

CREATE TABLE pendingbot.mcp_servers (
    id                    uuid DEFAULT pendingbot.uuidv7() NOT NULL,
    -- Stable handle the worker uses to look up a server (logs, billing,
    -- per-tool routing). Lowercase kebab-case by convention.
    name                  text NOT NULL,
    url                   text NOT NULL,
    -- Streamable HTTP is the only transport implemented in v1; 'sse'
    -- placeholder for future MCP servers that only speak the legacy
    -- SSE transport.
    transport             text NOT NULL DEFAULT 'http',
    -- Auth scheme. 'none' = no header. 'header' = inject
    -- `auth_header_name: <env[secret_ref]>` on every request.
    auth_kind             text NOT NULL DEFAULT 'none',
    auth_header_name      text,
    -- Cloudflare Workers env variable name (e.g. 'EXA_API_KEY'). The
    -- worker resolves this at request time; the actual secret never
    -- travels through Postgres.
    secret_ref            text,
    enabled               boolean NOT NULL DEFAULT true,
    notes                 text,
    -- Populated by a future health-check job; surfaces in the admin
    -- page as "last seen ok / last error". NULL until first probe.
    last_health_check_at  timestamptz,
    last_health_error     text,
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT mcp_servers_pkey PRIMARY KEY (id),
    CONSTRAINT mcp_servers_name_uniq UNIQUE (name),
    CONSTRAINT mcp_servers_transport_chk CHECK (transport IN ('http','sse')),
    CONSTRAINT mcp_servers_auth_kind_chk CHECK (auth_kind IN ('none','header')),
    -- 'header' auth requires both a header name and a secret ref; 'none'
    -- must leave them null. Enforced here so an admin can't save a
    -- half-configured row that would silently send unauthenticated.
    CONSTRAINT mcp_servers_auth_consistency_chk CHECK (
        (auth_kind = 'none'   AND auth_header_name IS NULL AND secret_ref IS NULL)
     OR (auth_kind = 'header' AND auth_header_name IS NOT NULL AND secret_ref IS NOT NULL)
    )
);
ALTER TABLE pendingbot.mcp_servers OWNER TO postgres;

COMMENT ON TABLE pendingbot.mcp_servers IS
    'Upstream MCP servers the edge worker dials. Backs the board '
    '"MCP servers" admin page. Secret values live in Cloudflare '
    'Workers Secrets — only the env var *name* is stored here.';

CREATE INDEX idx_mcp_servers_enabled
    ON pendingbot.mcp_servers(enabled)
    WHERE enabled = true;

ALTER TABLE pendingbot.mcp_servers ENABLE ROW LEVEL SECURITY;
-- No public/authenticated GRANTs. Workers read via service_role; ops
-- edits via the board which goes through supabaseAdmin (also
-- service_role).
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pendingbot.mcp_servers TO service_role;

-- Seed Exa as the first row, matching what the worker hardcodes today
-- in apps/edge/src/mcp/client.ts. After this migration + the runtime
-- refactor, the hardcoded URL/header go away and Exa is just row 1.
INSERT INTO pendingbot.mcp_servers
    (name, url, transport, auth_kind, auth_header_name, secret_ref, notes)
VALUES
    ('exa', 'https://mcp.exa.ai/mcp', 'http', 'header', 'x-api-key', 'EXA_API_KEY',
     'Default web_search_exa / web_fetch_exa provider');

COMMIT;
