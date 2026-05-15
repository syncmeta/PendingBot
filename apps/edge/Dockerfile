FROM docker.io/cloudflare/sandbox:0.10.1

# Pre-bake the Python data-stack the chat agent's execute_code tool reaches
# for. Baking them into the image (instead of pip-installing on first use,
# the way the Daytona path did) means a fresh sandbox can run user code on
# the first call — no cold pip-install latency, no per-conversation
# bootstrap bookkeeping.
RUN pip install --no-cache-dir \
    numpy \
    pandas \
    matplotlib \
    pillow \
    requests \
    httpx \
    python-dateutil

# Required for local `wrangler dev` port-exposure smoke tests; harmless
# when no service is bound to the port in production.
EXPOSE 8080
