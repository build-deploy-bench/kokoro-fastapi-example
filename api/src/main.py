"""
FastAPI OpenAI Compatible API
"""

import asyncio
import logging
import os
import sys
import time
from contextlib import asynccontextmanager

import torch
import uvicorn
from fastapi import Depends, FastAPI
from fastapi.middleware.cors import CORSMiddleware
from loguru import logger

from .core.auth import require_api_key
from .core.body_limit import BodySizeLimitMiddleware
from .core.config import settings, unrecognized_env_file_keys
from .routers.cartesia_compatible import router as cartesia_router
from .routers.debug import router as debug_router
from .routers.development import router as dev_router
from .routers.elevenlabs_compatible import router as elevenlabs_router
from .routers.openai_compatible import router as openai_router
from .routers.openai_realtime import router as realtime_router
from .routers.ssml import router as ssml_router
from .routers.tune import router as tune_router
from .routers.web_player import router as web_router


def setup_logger():
    """Configure loguru logger with custom formatting"""
    valid_levels = ["TRACE", "DEBUG", "INFO", "SUCCESS", "WARNING", "ERROR", "CRITICAL"]
    level = os.getenv("API_LOG_LEVEL", "DEBUG").upper()
    if level not in valid_levels:
        level = "DEBUG"
    print(f"Global API loguru logger level: {level}")
    config = {
        "handlers": [
            {
                "sink": sys.stdout,
                "format": "<fg #2E8B57>{time:hh:mm:ss A}</fg #2E8B57> | "
                "{level: <8} | "
                "<fg #4169E1>{module}:{line}</fg #4169E1> | "
                "{message}",
                "colorize": True,
                "level": level,
            },
        ],
    }
    logger.remove()
    logger.configure(**config)
    logger.level("ERROR", color="<red>")


# Configure logger
setup_logger()

# unknown keys are ignored rather than fatal, so name them or a typo'd setting fails silently
for _key in unrecognized_env_file_keys():
    logger.warning(f"ignoring unrecognized env file key: {_key}")


class _WebPlayerStartupHandler(logging.Handler):
    """Log the web player URL from uvicorn's bound address."""

    def emit(self, record: logging.LogRecord) -> None:
        if not str(record.msg).startswith("Uvicorn running on %s://"):
            return
        scheme, host, port = record.args
        logger.info(f"Beta Web Player: {scheme}://{host}:{port}/web/")
        logger.info(f"              or {scheme}://localhost:{port}/web/")


if settings.enable_web_player:
    logging.getLogger("uvicorn.error").addHandler(_WebPlayerStartupHandler())


class _BenchListeningHandler(logging.Handler):
    """Print the benchmark listening marker when uvicorn has bound its socket.

    uvicorn logs "Uvicorn running on" after the lifespan startup (model load and warmup) and the bind, so the marker
    is the time from which the app accepts connections. It carries the wall-clock time in epoch milliseconds.
    """

    def emit(self, record: logging.LogRecord) -> None:
        if str(record.msg).startswith("Uvicorn running on"):
            print(f"::bench::listening {time.time_ns() // 1_000_000}", flush=True)


logging.getLogger("uvicorn.error").addHandler(_BenchListeningHandler())


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Lifespan context manager for model initialization"""
    from .inference.model_manager import get_manager
    from .inference.voice_manager import get_manager as get_voice_manager
    from .services.temp_manager import cleanup_temp_files

    # Clean old temp files on startup
    await cleanup_temp_files()

    logger.info("Loading TTS model and voice packs...")

    try:
        # Initialize managers
        model_manager = await get_manager()
        voice_manager = await get_voice_manager()

        # Initialize model with warmup and get status
        device, model, voicepack_count = await model_manager.initialize_with_warmup(
            voice_manager
        )

    except Exception as e:
        logger.error(f"Failed to initialize model: {e}")
        raise

    if settings.enable_inno_tuner:
        from .inference import inno_tuner

        try:
            await asyncio.to_thread(inno_tuner.load)
        except Exception as e:
            logger.error(f"Inno voice tuner not loaded, /dev/tune will answer 503: {e}")

    boundary = "░" * 2 * 12
    startup_msg = f"""

{boundary}

    ╔═╗┌─┐┌─┐┌┬┐
    ╠╣ ├─┤└─┐ │ 
    ╚  ┴ ┴└─┘ ┴
    ╦╔═┌─┐┬┌─┌─┐
    ╠╩╗│ │├┴┐│ │
    ╩ ╩└─┘┴ ┴└─┘

{boundary}
                """
    startup_msg += f"\nModel warmed up on {device}: {model}"
    if device == "mps":
        startup_msg += "\nUsing Apple Metal Performance Shaders (MPS)"
    elif device == "cuda":
        startup_msg += f"\nCUDA: {torch.cuda.is_available()}"
    else:
        startup_msg += "\nRunning on CPU"
    startup_msg += f"\n{voicepack_count} voice packs loaded"
    if settings.enable_inno_tuner:
        startup_msg += "\nInno voice tuner: " + (
            "ready at /dev/tune" if inno_tuner.available() else "not available"
        )

    if settings.enable_web_player:
        startup_msg += "\n\nWeb Player: enabled (URL logged below)"
    else:
        startup_msg += "\n\nWeb Player: disabled"

    startup_msg += f"\n{boundary}\n"
    logger.info(startup_msg)

    yield


# Initialize FastAPI app
app = FastAPI(
    title=settings.api_title,
    description=settings.api_description,
    version=settings.api_version,
    lifespan=lifespan,
    openapi_url="/openapi.json",  # Explicitly enable OpenAPI schema
)


app.add_middleware(BodySizeLimitMiddleware)

# Add CORS middleware if enabled
if settings.cors_enabled:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origins,
        allow_credentials=False,
        allow_methods=["*"],
        allow_headers=["*"],
    )


# Include routers
protected = [Depends(require_api_key)]
app.include_router(openai_router, prefix="/v1", dependencies=protected)
app.include_router(dev_router, dependencies=protected)  # Development endpoints
app.include_router(
    ssml_router, dependencies=protected
)  # SSML translation and capabilities
app.include_router(tune_router, dependencies=protected)  # /dev/tune, 403 unless enabled
app.include_router(
    debug_router, dependencies=protected
)  # Debug endpoints (403 unless enabled)
app.include_router(
    elevenlabs_router, dependencies=protected
)  # ElevenLabs compatible websocket TTS
app.include_router(
    cartesia_router, dependencies=protected
)  # Cartesia compatible websocket TTS
app.include_router(
    realtime_router, dependencies=protected
)  # OpenAI Realtime compatible websocket TTS
if settings.enable_web_player:
    app.include_router(web_router, prefix="/web")  # Web player static files


# Health check endpoint
@app.get("/health")
async def health_check():
    """Health check endpoint"""
    return {"status": "healthy"}


def _read_build_commit() -> str:
    """Return the commit that bench/build.sh recorded at build time, or "unknown" without a build."""
    try:
        with open(os.path.join(os.path.dirname(__file__), "..", "..", ".build-commit")) as f:
            return f.read().strip() or "unknown"
    except FileNotFoundError:
        return "unknown"


BUILD_COMMIT = _read_build_commit()
# The benchmark harness sets BENCH_RUN_ID before each deploy, and each deployment keeps the env it started with.
RUN_ID = os.environ.get("BENCH_RUN_ID") or "unknown"
# Railway gets no BENCH_RUN_ID: a changed variable invalidates part of its build cache. Its own deployment ID
# identifies the deployment instead.
DEPLOYMENT_ID = os.environ.get("RAILWAY_DEPLOYMENT_ID") or "unknown"


@app.get("/version")
async def version():
    """Identify the running deployment for the build-deploy benchmark."""
    return {"commit": BUILD_COMMIT, "run": RUN_ID, "deployment": DEPLOYMENT_ID}


@app.get("/v1/test")
async def test_endpoint():
    """Test endpoint to verify routing"""
    return {"status": "ok"}


if __name__ == "__main__":
    uvicorn.run("api.src.main:app", host=settings.host, port=settings.port, reload=True)
