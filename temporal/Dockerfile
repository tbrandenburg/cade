# M8 Temporal worker image: multi-stage build (uv-managed venv built in a
# `builder` stage, only the resulting `.venv` copied into a slim `runtime`
# stage), non-root runtime user — mirrors the pattern documented in
# `tbrandenburg/temporal-sandbox`'s Dockerfile (see M8 step notes).

FROM python:3.13-slim AS builder

COPY --from=ghcr.io/astral-sh/uv:0.9.9 /uv /uvx /usr/local/bin/

# Optional corporate/TLS-intercepting-proxy CA bundle. Passed as a BuildKit
# secret (never a build arg or COPY) so it never lands in an image layer:
#   make temporal-worker-build CACERT=/path/to/ca-bundle.pem
# On unrestricted networks this mount is empty and the step is a no-op.
RUN --mount=type=secret,id=cacert \
    if [ -s /run/secrets/cacert ]; then \
      apt-get update && apt-get install -y --no-install-recommends ca-certificates \
      && cp /run/secrets/cacert /usr/local/share/ca-certificates/corporate-ca.crt \
      && update-ca-certificates \
      && rm -rf /var/lib/apt/lists/*; \
    fi

ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    UV_NATIVE_TLS=1

WORKDIR /build
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

COPY src ./src

FROM python:3.13-slim AS runtime

RUN groupadd --gid 1000 demo \
    && useradd --uid 1000 --gid demo --create-home --shell /usr/sbin/nologin demo

WORKDIR /app
COPY --from=builder /build/.venv /app/.venv
COPY --from=builder /build/src /app/src

ENV PATH="/app/.venv/bin:${PATH}" \
    PYTHONPATH="/app/src" \
    PYTHONUNBUFFERED=1

RUN mkdir -p /var/lib/demo-worker && chown -R demo:demo /var/lib/demo-worker /app

USER demo

ENTRYPOINT ["python", "-m", "demo.worker"]
