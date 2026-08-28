# M11 Lab Simulator image: multi-stage build (uv-managed venv built in a
# `builder` stage, only the resulting `.venv` copied into a slim `runtime`
# stage), non-root runtime user - mirrors `temporal/Dockerfile`'s pattern
# (M8).

FROM python:3.13-slim AS builder

COPY --from=ghcr.io/astral-sh/uv:0.9.9 /uv /uvx /usr/local/bin/

WORKDIR /build
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

COPY src ./src

FROM python:3.13-slim AS runtime

RUN groupadd --gid 1000 labsim \
    && useradd --uid 1000 --gid labsim --create-home --shell /usr/sbin/nologin labsim

WORKDIR /app
COPY --from=builder /build/.venv /app/.venv
COPY --from=builder /build/src /app/src
COPY healthcheck.py /app/healthcheck.py

ENV PATH="/app/.venv/bin:${PATH}" \
    PYTHONPATH="/app/src" \
    PYTHONUNBUFFERED=1 \
    LAB_SIM_PORT=8300

RUN chown -R labsim:labsim /app

USER labsim

EXPOSE 8300

ENTRYPOINT ["python", "-m", "lab_sim.server"]
