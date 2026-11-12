# Benchmark image for all four providers (Render, Railway and Fly build it as `Dockerfile`; Vercel through
# `"framework": "container"` in vercel.json). Derived from docker/cpu/Dockerfile.optimized. BENCH.md lists the
# differences. It uses no BuildKit-only syntax (`# syntax=`, `RUN --mount`, `COPY --exclude`), because Vercel builds
# with Buildah.

# Stage 1: Builder. Base images are pinned to the patch release that the upstream tags resolved to on 2026-11-12.
FROM python:3.12.16-trixie AS builder

# Install build dependencies (g++/cmake/make: pyopenjtalk ships sdist only)
RUN apt-get update -y && \
    apt-get install -y git curl g++ cmake make

# A pinned uv instead of the upstream `curl | sh` installer, which installs the latest release.
COPY --from=ghcr.io/astral-sh/uv:0.13.6 /uv /uvx /usr/local/bin/

WORKDIR /app

# Install inputs only, so a change to the app sources keeps this stage cached.
COPY pyproject.toml uv.lock ./
COPY docker/scripts/download_model.py ./download_model.py
COPY bench/build.sh ./bench/build.sh

# UV_NO_CACHE replaces the upstream cache mount: the cache would only grow this stage's layer.
# UV_PYTHON_DOWNLOADS=never keeps the venv on the image's Python, which the runtime stage also has.
# HF_HUB_DISABLE_TELEMETRY skips the unpinned Hugging Face version checks in download_model.py (see the runtime stage).
ENV UV_HTTP_TIMEOUT=120 UV_HTTP_RETRIES=3 UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_NO_CACHE=1 \
    UV_PYTHON_DOWNLOADS=never HF_HUB_DISABLE_TELEMETRY=1

# Python packages (CPU torch), model weights and the UniDic dictionary for Japanese.
RUN sh ./bench/build.sh install

# Stage 2: Runtime - slim image
FROM python:3.12.16-slim-trixie

# Install runtime dependencies
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends espeak-ng espeak-ng-data libsndfile1 curl libjemalloc2 && \
    apt-get clean && rm -rf /var/lib/apt/lists/* && \
    mkdir -p /usr/share/espeak-ng-data && \
    ln -s /usr/lib/*/espeak-ng-data/* /usr/share/espeak-ng-data/ && \
    useradd -m -u 1000 appuser && \
    mkdir -p /app/api/src/models/v1_0 && \
    chown -R appuser:appuser /app

WORKDIR /app

# Copy virtual environment (with the UniDic dictionary) and the model from the builder. They are separate layers,
# and both come before the app sources, so a source change reuses them.
COPY --from=builder --chown=appuser:appuser /app/.venv /app/.venv
COPY --from=builder --chown=appuser:appuser /app/api/src/models ./api/src/models

# Copy project files. api/src/models/v1_0/config.json in the repo is the same file that the builder downloaded
# (download_model.py checks its digest), so this copy does not change the model.
COPY --chown=appuser:appuser docker/scripts/download_model.py ./download_model.py
COPY --chown=appuser:appuser api ./api
COPY --chown=appuser:appuser web ./web
COPY --chown=appuser:appuser VERSION ./VERSION
COPY --chown=appuser:appuser docker/scripts/entrypoint.sh ./entrypoint.sh
COPY --chown=appuser:appuser bench/build.sh ./bench/build.sh
RUN chmod +x ./entrypoint.sh

USER appuser

# Set environment variables
# HF_HUB_DISABLE_TELEMETRY turns off the Hugging Face version checks that download_model.py makes at every start, so
# boot does not wait on an outside service.
ENV PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app:/app/api \
    PATH="/app/.venv/bin:$PATH" \
    USE_GPU=false \
    PHONEMIZER_ESPEAK_PATH=/usr/bin \
    PHONEMIZER_ESPEAK_DATA=/usr/share/espeak-ng-data \
    ESPEAK_DATA_PATH=/usr/share/espeak-ng-data \
    DEVICE="cpu" \
    LD_PRELOAD=libjemalloc.so.2 \
    MALLOC_CONF=oversize_threshold:0,background_thread:true,dirty_decay_ms:30000,muzzy_decay_ms:30000 \
    HF_HUB_DISABLE_TELEMETRY=1

# The provider passes the commit as a build arg (Render: RENDER_GIT_COMMIT, Railway: RAILWAY_GIT_COMMIT_SHA, Vercel:
# VERCEL_GIT_COMMIT_SHA; Fly: the harness sets BENCH_COMMIT). Declared here, so a new commit does not invalidate
# the layers above.
ARG BENCH_COMMIT
ARG RENDER_GIT_COMMIT
ARG RAILWAY_GIT_COMMIT_SHA
ARG VERCEL_GIT_COMMIT_SHA
RUN sh ./bench/build.sh build

EXPOSE 8880

# Run FastAPI server
CMD ["./entrypoint.sh"]
