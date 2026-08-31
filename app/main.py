from __future__ import annotations

import logging
import time
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request
from fastapi.responses import JSONResponse

from . import normalize
from .cache import build_cache, cache_key
from .config import Settings, get_settings
from .schemas import (
    ErrorResponse,
    Health,
    Profile,
    ProfileRequest,
    Source,
)
from .session import SessionManager
from .sources.voyager import VoyagerError
from .urls import InvalidProfileURL, parse_public_identifier

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("linkedin-profile-api")


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = get_settings()
    app.state.cache = build_cache(settings.redis_url)
    app.state.session = SessionManager(settings)
    await app.state.session.start()

    if not app.state.session.available and not app.state.session.can_self_heal:
        log.warning("No LinkedIn session available; /v1/profile will return 503.")

    try:
        yield
    finally:
        await app.state.session.aclose()
        await app.state.cache.aclose()


app = FastAPI(
    title="LinkedIn Profile API",
    version="1.0.0",
    description=(
        "Accepts a LinkedIn member profile URL and returns the profile as "
        "structured JSON. See the repository README for scope, legal "
        "considerations and known limitations."
    ),
    lifespan=lifespan,
)


# ------------------------------------------------------------------------ auth


def require_api_key(
    settings: Settings = Depends(get_settings),
    x_api_key: str | None = Header(default=None, alias="X-API-Key"),
) -> None:
    if x_api_key not in settings.api_key_set:
        raise HTTPException(
            status_code=401,
            detail={
                "code": "UNAUTHORIZED",
                "message": "Provide a valid X-API-Key header.",
                "retryable": False,
            },
        )


# ------------------------------------------------------------- error handling


@app.exception_handler(HTTPException)
async def http_exception_handler(_: Request, exc: HTTPException) -> JSONResponse:
    detail = exc.detail
    if not isinstance(detail, dict):
        detail = {"code": "ERROR", "message": str(detail), "retryable": False}
    return JSONResponse(status_code=exc.status_code, content={"error": detail})


@app.exception_handler(VoyagerError)
async def voyager_exception_handler(_: Request, exc: VoyagerError) -> JSONResponse:
    return JSONResponse(
        status_code=exc.http_status,
        content={
            "error": {
                "code": exc.code,
                "message": str(exc),
                "retryable": exc.retryable,
            }
        },
    )


# --------------------------------------------------------------------- routes


@app.get("/healthz", response_model=Health, tags=["meta"])
async def healthz(settings: Settings = Depends(get_settings)) -> Health:
    healthy = app.state.session.available
    return Health(
        status="ok" if healthy else "degraded",
        linkedin_session_configured=healthy,
        auth_mode=(
            "credentials" if settings.has_linkedin_credentials
            else "cookies" if settings.has_linkedin_session
            else "none"
        ),
        can_self_heal=app.state.session.can_self_heal,
        cache_backend=app.state.cache.name,
    )


async def _resolve(url: str, refresh: bool, settings: Settings) -> Profile:
    try:
        public_identifier = parse_public_identifier(url)
    except InvalidProfileURL as exc:
        raise HTTPException(
            status_code=400,
            detail={"code": "INVALID_URL", "message": str(exc), "retryable": False},
        ) from exc

    key = cache_key(public_identifier)

    if not refresh:
        cached = await app.state.cache.get(key)
        if cached:
            profile = Profile.model_validate(cached)
            profile.meta.cache_hit = True
            profile.meta.source = Source.CACHE
            return profile

    if not app.state.session.available and not app.state.session.can_self_heal:
        raise HTTPException(
            status_code=503,
            detail={
                "code": "NO_SESSION",
                "message": "No LinkedIn session is configured on this deployment.",
                "retryable": False,
            },
        )

    started = time.perf_counter()
    bundle, unavailable = await app.state.session.fetch_all(public_identifier)
    elapsed_ms = int((time.perf_counter() - started) * 1000)

    profile = normalize.from_voyager(
        public_identifier, bundle, unavailable=unavailable, duration_ms=elapsed_ms
    )
    await app.state.cache.set(
        key, profile.model_dump(mode="json"), settings.cache_ttl_seconds
    )
    return profile


@app.post(
    "/v1/profile",
    response_model=Profile,
    tags=["profile"],
    responses={
        400: {"model": ErrorResponse},
        401: {"model": ErrorResponse},
        404: {"model": ErrorResponse},
        503: {"model": ErrorResponse},
    },
)
async def post_profile(
    body: ProfileRequest,
    settings: Settings = Depends(get_settings),
    _: None = Depends(require_api_key),
) -> Profile:
    return await _resolve(body.url, body.refresh, settings)


@app.get("/v1/profile", response_model=Profile, tags=["profile"])
async def get_profile(
    url: str = Query(..., description="A LinkedIn member profile URL."),
    refresh: bool = Query(False),
    settings: Settings = Depends(get_settings),
    _: None = Depends(require_api_key),
) -> Profile:
    """Convenience GET so the API is testable from a browser or plain curl."""
    return await _resolve(url, refresh, settings)

