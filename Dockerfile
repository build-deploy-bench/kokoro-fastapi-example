# Benchmark image for all four providers (Render, Railway and Fly build it as `Dockerfile`; Vercel through the
# `builds` entry in vercel.json). Derived from docker/cpu/Dockerfile.optimized. BENCH.md lists the
# differences. It uses no BuildKit-only syntax (`# syntax=`, `RUN --mount`, `COPY --exclude`), because Vercel builds
# with Buildah.

# Stage 1: Builder. It runs both bench steps, so the install and build steps are next to each other in every build
# log. Base images are pinned by tag and digest to what the upstream tags resolved to on 2026-11-12.
FROM python:3.12.16-trixie@sha256:271e78638e5d4e8aeeeb4c1e72cb40c56be3add83a92eaa99b7aab83955121c0 AS builder

# Install build dependencies (g++/cmake/make: pyopenjtalk ships sdist only)
RUN apt-get update -y && \
    apt-get install -y git curl g++ cmake make

# A pinned uv instead of the upstream `curl | sh` installer, which installs the latest release.
COPY --from=ghcr.io/astral-sh/uv:0.13.6@sha256:af22a52f5eafef3d78e551599d405c02df61919d18028f0cea8eda93bc9986d0 /uv /uvx /usr/local/bin/

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

# The image has no .git, so the commit for /version comes from a build arg (Render: RENDER_GIT_COMMIT, Railway:
# RAILWAY_GIT_COMMIT_SHA, Vercel: VERCEL_GIT_COMMIT_SHA on Git deploys; the harness passes BENCH_COMMIT to Fly). A
# RUN step sees a build arg only after its ARG line. The ARGs come after the install step, so a new commit does not
# invalidate the install layer.
ARG BENCH_COMMIT=""
ARG RENDER_GIT_COMMIT=""
ARG RAILWAY_GIT_COMMIT_SHA=""
ARG VERCEL_GIT_COMMIT_SHA=""

# App sources. api/src/models/v1_0/config.json in the repo is the same file that the install step downloaded to
# models/ (download_model.py checks its digest), so the runtime stage can copy both into api/src/models.
COPY api ./api
COPY web ./web
COPY VERSION ./VERSION
COPY docker/scripts/entrypoint.sh ./entrypoint.sh
RUN sh ./bench/build.sh build

# Stage 2: Runtime - slim image
FROM python:3.12.16-slim-trixie@sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b

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

# Copy virtual environment (with the UniDic dictionary), the model and then the app from the builder. The venv and
# the model come first, so a source change reuses their layers.
COPY --from=builder --chown=appuser:appuser /app/.venv /app/.venv
COPY --from=builder --chown=appuser:appuser /app/models ./api/src/models
COPY --chown=appuser:appuser docker/scripts/download_model.py ./download_model.py
COPY --from=builder --chown=appuser:appuser /app/api ./api
COPY --from=builder --chown=appuser:appuser /app/web ./web
COPY --from=builder --chown=appuser:appuser /app/VERSION /app/.build-commit ./
COPY --from=builder --chown=appuser:appuser /app/entrypoint.sh ./entrypoint.sh
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

# The app listens on $PORT. It keeps the upstream port 8880: the image runs as the non-root appuser, which cannot
# bind 80. Render and Railway set PORT at runtime, Vercel routes to the project env var PORT=8880, and Fly uses
# internal_port = 8880.
ENV PORT=8880
EXPOSE 8880

# Run FastAPI server
CMD ["./entrypoint.sh"]
