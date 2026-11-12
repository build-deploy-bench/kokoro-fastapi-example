#!/bin/bash
set -e

# Benchmark start marker: the start command begins. It carries the wall-clock time in epoch milliseconds.
echo "::bench::start $(date +%s%3N)"

if [ "${DOWNLOAD_MODEL:-true}" = "true" ]; then
    python download_model.py --output api/src/models/v1_0
fi

exec python -m uvicorn api.src.main:app --host "${HOST:-0.0.0.0}" --port "${PORT:-8880}" --log-level debug