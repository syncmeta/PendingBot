# Group-voice media container. Bun owns the OpenAI/audio loop. Chromium is
# installed so the container can run a headless Cloudflare RealtimeKit
# participant for bot audio.
#
# Cloudflare Containers require linux/amd64; pin it so a build on an arm
# Mac still produces an amd64 image.
FROM --platform=linux/amd64 oven/bun:1.3

WORKDIR /app

USER root
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    chromium \
    fonts-liberation \
  && rm -rf /var/lib/apt/lists/*
ENV CHROMIUM_PATH=/usr/bin/chromium

# Source only — the worker reaches every endpoint, nothing binds publicly.
COPY package.json ./
RUN bun install --production
COPY src ./src

# Readiness probe target (Container pingEndpoint defaults to /ping) and the
# port the worker's container binding forwards to (defaultPort = 8080).
EXPOSE 8080

CMD ["bun", "run", "src/index.ts"]
