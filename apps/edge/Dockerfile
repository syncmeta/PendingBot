FROM docker.io/cloudflare/sandbox:0.10.1-python

# The `-python` variant of the base already ships Python 3.11 with
# numpy/pandas/matplotlib/ipython baked in. We just top up with the rest
# of the data-stack the chat agent's execute_code tool reaches for.
# Baking them into the image (instead of pip-installing on first use)
# means a fresh sandbox can run user code on the first call — no cold
# pip-install latency, no per-conversation bootstrap bookkeeping.
RUN python3 -m pip install --no-cache-dir \
    pillow \
    requests \
    httpx \
    python-dateutil

# Required for local `wrangler dev` port-exposure smoke tests; harmless
# when no service is bound to the port in production.
EXPOSE 8080
