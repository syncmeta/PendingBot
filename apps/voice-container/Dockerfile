# Group-voice media container. Plain Bun runtime — no npm dependencies
# (only Bun built-ins: Bun.serve, WebSocket client, Buffer), so there is
# no `bun install` step and the image stays tiny.
#
# Cloudflare Containers require linux/amd64; pin it so a build on an arm
# Mac still produces an amd64 image.
FROM --platform=linux/amd64 oven/bun:1.3

WORKDIR /app

# Source only — the worker reaches every endpoint, nothing binds publicly.
COPY package.json ./
COPY src ./src

# Readiness probe target (Container pingEndpoint defaults to /ping) and the
# port the worker's container binding forwards to (defaultPort = 8080).
EXPOSE 8080

CMD ["bun", "run", "src/index.ts"]
