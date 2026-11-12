# Build-deploy benchmark fixture: Docker large (Kokoro-FastAPI, CPU)

## Source

- Upstream: https://github.com/remsky/Kokoro-FastAPI at tag `v0.10.0` = `f2a5270d2ccd9590bc87e2393c774814f23fe7a1` (2026-11-08). Apache-2.0, kept in `LICENSE`.
- This repo: https://github.com/build-deploy-bench/kokoro-fastapi-example (private, independent copy). The first commit is the unmodified upstream tree (same tree hash as the tag).
- The app is FastAPI text-to-speech on CPU torch. It needs no external service at runtime.

## Patches

1. Removed the upstream GitHub Actions workflows and `dependabot.yml`.
2. Added a root `Dockerfile`, derived from `docker/cpu/Dockerfile.optimized` (which stays unchanged). All four providers build this file. Differences from the upstream file:
   - No BuildKit-only syntax (`# syntax=`, `RUN --mount=type=cache`, `COPY --exclude`), because Vercel builds with Buildah. `UV_NO_CACHE=1` replaces the cache mount.
   - uv comes from `ghcr.io/astral-sh/uv:0.13.6` instead of the unpinned `curl | sh` installer.
   - Base images and uv pinned by tag and digest: `python:3.12.16-trixie`, `python:3.12.16-slim-trixie` (what the upstream tags `python:3.12` and `python:3.12-slim` resolved to on 2026-11-12) and `ghcr.io/astral-sh/uv:0.13.6`.
   - Both bench steps run in the builder stage, as the harness convention for Docker fixtures asks: `RUN sh ./bench/build.sh install`, then the commit `ARG`s and the app sources, then `RUN sh ./bench/build.sh build`. The model and UniDic downloads moved from the runtime stage into the install step. The model goes to `models/` outside `api/`, so the app source layer does not carry it again. The runtime stage copies the venv (which contains UniDic), the model and then the app from the builder, in that order, so a source change reuses the two large layers.
   - `HF_HUB_DISABLE_TELEMETRY=1` in both stages. `download_model.py` runs at every container start (upstream entrypoint) and, without it, makes two unpinned Hugging Face GETs (3 s timeout each) before the server starts.
   - Build args `BENCH_COMMIT`, `RENDER_GIT_COMMIT`, `RAILWAY_GIT_COMMIT_SHA`, `VERCEL_GIT_COMMIT_SHA` declared after the install step.
   - `ENV PORT=8880`. The harness convention is `PORT=80`, but the image runs as the non-root `appuser` (upstream), which cannot bind 80.
3. UniDic is pinned. `python -m unidic download` reads the URL from a moving JSON file on GitHub. `bench/build.sh` downloads `unidic-3.1.0.zip` (the current `latest`) from the same S3 host, checks its SHA-256 and then calls the same `download_and_clean()` function. The model download (`download_model.py`) was already pinned to a Hugging Face commit and checked by SHA-256; the Inno tuner weights to a tag and SHA-256.
4. `GET /version` in `api/src/main.py` returns `{"commit","run","deployment"}`. `commit` is `.build-commit`, written by `bench/build.sh build` from `BENCH_COMMIT`, `RENDER_GIT_COMMIT`, `RAILWAY_GIT_COMMIT_SHA`, `VERCEL_GIT_COMMIT_SHA`, then `git rev-parse HEAD`, else `unknown`. `run` is `BENCH_RUN_ID`, `deployment` is `RAILWAY_DEPLOYMENT_ID` (else `unknown`), as in the other fixtures.
5. Runtime markers: `docker/scripts/entrypoint.sh` (the image `CMD`) prints `::bench::start` as its first action. A `uvicorn.error` log handler in `api/src/main.py` prints `::bench::listening` on uvicorn's `Uvicorn running on` line, which comes after the lifespan startup (model load and warmup) and the socket bind.
6. `api/src/bench_touch.py` is the touch file for warm runs. It is under `api/`, which the Dockerfile copies after the install step and before the build step. It is not imported. The harness rewrites the whole touch file, so it cannot be `api/src/main.py`.
7. `vercel.json` has `"builds": [{"src": "Dockerfile", "use": "@vercel/container"}]` instead of `"framework": "container"`. With the framework preset, Vercel's zero-config detection also makes every `api/**/*.py` file a Python function; that bundle (6.7 GB) failed the 500 MB function limit after the image was already pushed (`dpl_Ca3rPAfE3PGbBXoT6T97gtRjLwtv`). The `builds` entry turns zero-config detection off. Vercel prints a warning that the project's Build and Development Settings do not apply.

## Commands

| Step | Command | Markers |
|---|---|---|
| Install | `./bench/build.sh install` = `uv venv` + `uv sync --frozen --extra cpu --no-install-project` + `download_model.py` + UniDic | `::bench::install_start` / `::bench::install_done` |
| Build | `./bench/build.sh build` = `python -m compileall -q api` + `.build-commit` | `::bench::build_start` / `::bench::build_done` |
| Start | `./entrypoint.sh` (`download_model.py` check, then `uvicorn api.src.main:app --port $PORT`) | `::bench::start` / `::bench::listening` |
| Health | `GET /health` returns 200 `{"status":"healthy"}` | |

The app has no compile step, as in the Python fixture, so the build phase is under 1 s. The install phase is about 2 to 2.5 minutes on Render, Railway and Vercel: torch and 130 other packages (uv compiles their bytecode), `pyopenjtalk` built from source, the 327 MB model from Hugging Face and the 526 MB UniDic zip from S3 in Tokyo.

Port: the app listens on `PORT`; the image sets 8880 (the upstream port). Render, Railway and Vercel also have the env var `PORT=8880` (on Vercel it sets the routed port); Fly uses `internal_port = 8880`.

## Image

- 1.61 GB compressed (Railway push `total_size`), 4.5 GB on disk locally (arm64 build). 51,000 files. The largest layer is the venv COPY (2.45 GB uncompressed, including the 775 MB UniDic dictionary); the model layer is 351 MB; the `api/` layer is 40 MB (mostly voice packs).
- Limits that apply: Vercel 2 GB per compressed layer and 15 GB per image, Fly about 8 GB uncompressed, Render 10 GB. None is close.

## Memory and instance size

Measured locally with `docker run --cpus=1 --memory=<limit>` (arm64 image) on 2026-11-12:

- 1 GB: killed by the OOM killer during startup.
- 1.5 GB: boots and answers a TTS request, but the cgroup sits at its limit (peak 1.5 GiB).
- 2 GB: boots in about 10 s; after one TTS request `anon` memory is 1.39 GiB.

All providers use 2 GB: Render `standard` (1 CPU, 2 GB), Railway limits 1 vCPU / 2 GB, Fly `shared-cpu-1x` with 2048 MB, Vercel's default function memory (2 GB). Keep the services suspended or stopped outside measurements.

## Providers

### Render

- Workspace `tea-dbmbhbg8v5cc73e4m0jg`. Service `srv-dbquauuc6qcc7381stl0` `bdb-kokoro-fastapi`, https://bdb-kokoro-fastapi.onrender.com
- Runtime `docker`, `./Dockerfile`, context `.`. Region `virginia`. Instance plan `standard` ($25/month), build plan `starter`. Auto-deploy `no`. Health check `/health`. Env: `PORT=8880`, `BENCH_RUN_ID`.
- Setup deploy `dep-dbquav6c6qcc7381svag` of `56b9533` (the creation deploy): `live`. `/version` returned the right commit, so `RENDER_GIT_COMMIT` reaches the Dockerfile as a build arg. Install 119 s, push 20 s plus 90 s of cache export, `start` to `listening` 20 s.
- Suspended after the setup deploy.

### Railway

- Project `bdb-kokoro-fastapi` `9c278cfa-88f6-4a4d-8be7-fb9fc65dd755`, environment `production` `b9a5fa59-479e-40ef-80d0-a73bb9428f28`, service `767b0c1c-bf6a-4dd3-9aa3-75389f0397b4`. https://bdb-kokoro-fastapi-production.up.railway.app (domain on port 8880).
- Source `build-deploy-bench/kokoro-fastapi-example` `main`. Railway uses the root `Dockerfile`. Health check `/health`. Variables: `PORT=8880`. Limits: 1 vCPU, 2 GB (`serviceInstanceLimitsUpdate`). The other fixtures keep Railway's default limits; this one is limited to match the 2 GB instances on the other providers. Region not set (default).
- Auto-deploy disabled after `serviceConnect` and confirmed with `serviceInstanceAutoDeployStatus`.
- Setup deploy `5e83ddf3-bab0-4203-a70c-d06b2ad0d4c8` of `56b9533` (the connect deploy): `SUCCESS`. All four build markers, image push 1.61 GB in 66 s, `/version` returned the right commit and the deployment ID. `start` to `listening` took 85 s, much longer than on the other providers.
- Removed after the setup deploy (`deploymentRemove`).

### Vercel

- Team `build-deploy-bench`. Project `bdb-kokoro-fastapi` `prj_mxh7GMxqsrGsDAVeHlqxZUu8YblO`, https://bdb-kokoro-fastapi.vercel.app. No Git link; deploys upload a clean context with `vercel deploy --prod`.
- Container builder through `builds` in `vercel.json` (patch 7). Function region `iad1`, default memory 2 GB. Build machine `standard` (elastic, the project default; the build ran in `cle1`). Project env `PORT=8880` (production), which sets the routed port.
- Deploy `dpl_5ZUFCxYuWPAzmVuuB8QhyuCA2uEn` of `0dba0e3`: `READY`. All four build markers, install 133 s, build (Buildah total) 320 s, push 57 s. Vercel started four instances right after `READY`; each logged `::bench::listening`. `/version` returned `run` = `setup-vercel-2` and `commit` = `unknown` (no commit SHA after a CLI upload, the same as the other fixtures). The CLI log view showed only the last lines of each instance, without `::bench::start`.
- Scales to zero by itself.

### Fly.io

- Org `personal`. App `bdb-kokoro-fastapi`, https://bdb-kokoro-fastapi.fly.dev. `fly.toml`: one Machine, `iad`, `shared-cpu-1x` with 2048 MB, health check `/health`.
- Deploy: `flyctl deploy --config fly.toml -a bdb-kokoro-fastapi --remote-only --depot=false --ha=false --strategy bluegreen --yes --build-arg BENCH_COMMIT=<sha> --env BENCH_RUN_ID=<id>` from a `git archive` of the commit.
- **Not deployed yet.** Two setup deploys ran on 2026-11-12 while other fixtures used the same remote builder (`fly-builder-rosy-headland-8386`, `shared-cpu-8x`). The install step took 1,095 s (other providers: 120 to 150 s). The first deploy stopped when the local shell limit ended flyctl. The second built the image (install layer cached) but one layer push failed after retries; flyctl then rebuilt and the builder answered `unable to upgrade to h2c, received 500`. The app has no Machine. The matrix run waited 2 hours for the shared Fly build lock and did not start.

## Matrix check (2026-11-12)

`matrix/run.py --fixtures docker-large --runs cold,warm` from branch `fixture/docker-large` of the harness, output in `build-deploy-bench-runs/2026-11-12-docker-large-check`. Every run reached its provider's terminal success state, and the probe saw the run ID.

| Provider | Cold e2e | Warm e2e | Notes |
|---|---|---|---|
| Render | 356 s | 134 s | Resume (`service_resumed`) took 353 s before the runs. Cold cache export to the registry 110 s. Warm `observed_cache` is `partial` and has no install time. |
| Railway | 677 s | 367 s | App boot (start to listening) 134 s cold and 83 s warm on 1 vCPU, against 20 to 25 s on Render and 16 s on Vercel. |
| Vercel | 451 s | 607 s, 208 s | The first warm run restored the build cache of the setup deploy `dpl_5ZUFCxYuWPAzmVuuB8QhyuCA2uEn` (older `bench/build.sh`), not of the cold run, so the install step ran again. A second warm run hit the cache (restore 56 s, 3.3 GiB). |
| Fly | not run | not run | See Fly.io above. |
