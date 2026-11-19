#!/bin/sh
# Build steps of the root Dockerfile, the same on every provider. The ::bench:: markers delimit the install and build
# phases in the build log.
set -eu

# Each marker carries the wall-clock time in epoch milliseconds, so a parser does not depend on the time at which
# the provider received the log line. A `date` without %N (BusyBox) falls back to whole seconds.
mark() {
  now="$(date +%s%3N)"
  case "$now" in *[!0-9]*) now="$(date +%s)000" ;; esac
  printf '::bench::%s %s\n' "$1" "$now"
}

# UniDic 3.1.0, the version that `python -m unidic download` picks today. That command reads the URL from a moving
# JSON file on GitHub, so the zip is fetched directly and checked against this digest instead.
UNIDIC_URL="https://cotonoha-dic.s3-ap-northeast-1.amazonaws.com/unidic-3.1.0.zip"
UNIDIC_VERSION="3.1.0+2021-08-31"
UNIDIC_SHA256="638718c4c63625ab300de4c92c67925d54c0e9e3830009eaa992f29819d59c43"

# Install covers everything the app needs that is not its own source: the Python packages, the model weights and
# the Japanese dictionary. All three are pinned (uv.lock, the Hugging Face commit and digests in download_model.py,
# UNIDIC_SHA256).
install() {
  mark install_start
  uv venv --python 3.12
  uv sync --frozen --extra cpu --no-install-project
  # Outside api/, so the app source layers of the image do not contain the model again.
  .venv/bin/python download_model.py --output models/v1_0
  install_unidic
  mark install_done
}

install_unidic() {
  zip="$(mktemp)"
  curl -fsSL --retry 3 -o "$zip" "$UNIDIC_URL"
  printf '%s  %s\n' "$UNIDIC_SHA256" "$zip" | sha256sum -c -
  # download_and_clean() is what `python -m unidic download` runs after it resolves the URL. It extracts the zip
  # into the package directory, so the dictionary is part of the venv.
  .venv/bin/python -c 'import sys; from unidic.download import download_and_clean; download_and_clean(sys.argv[1], sys.argv[2])' \
    "$UNIDIC_VERSION" "file://$zip"
  rm -f "$zip"
}

# The app has no compile step. The closest equivalent is the bytecode compile of the app sources (the venv is
# compiled during install by UV_COMPILE_BYTECODE), plus the commit file that /version serves.
build() {
  mark build_start
  python -m compileall -q api
  write_commit
  mark build_done
}

# The deployed commit comes from the build environment, so an old deployment keeps reporting its own commit.
# BENCH_COMMIT is for builds without a provider variable (Fly, local); git is the last resort.
write_commit() {
  commit="${BENCH_COMMIT:-${RENDER_GIT_COMMIT:-${RAILWAY_GIT_COMMIT_SHA:-${VERCEL_GIT_COMMIT_SHA:-}}}}"
  if [ -z "$commit" ]; then
    commit="$(git rev-parse HEAD 2>/dev/null || printf 'unknown')"
  fi
  printf '%s\n' "$commit" > .build-commit
}

case "${1:-all}" in
  install) install ;;
  build) build ;;
  all) install; build ;;
  *) printf 'Usage: %s {install|build|all}\n' "$0" >&2; exit 2 ;;
esac
