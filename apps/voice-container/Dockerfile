# Group-voice media container. Bun owns the OpenAI/audio loop.
# chrome-headless-shell is installed so the container can run a lightweight
# headless Cloudflare RealtimeKit participant for bot audio.
#
# Cloudflare Containers require linux/amd64; pin it so a build on an arm
# Mac still produces an amd64 image.
FROM --platform=linux/amd64 oven/bun:1.3

WORKDIR /app

USER root
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    chromium-headless-shell \
  && rm -rf /var/lib/apt/lists/* \
  && /usr/bin/chromium-headless-shell --version
ENV CHROME_HEADLESS_SHELL_PATH=/usr/bin/chromium-headless-shell

# Source only — the worker reaches every endpoint, nothing binds publicly.
COPY package.json ./
RUN bun install --production
COPY src ./src

# Readiness probe target (Container pingEndpoint defaults to /ping) and the
# port the worker's container binding forwards to (defaultPort = 8080).
EXPOSE 8080

CMD ["bun", "run", "src/index.ts"]
