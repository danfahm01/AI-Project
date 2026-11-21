from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from app import __version__

router = APIRouter(prefix="/health", tags=["health"])


@router.get("/live", summary="Liveness probe")
async def live() -> dict[str, str]:
    return {"status": "ok", "version": __version__}


@router.get("/ready", summary="Readiness probe (database and rate-limit store)")
async def ready(request: Request) -> JSONResponse:
    checks = {
        "database": await request.app.state.db.ping(),
        "rate_limiter": await request.app.state.rate_limiter.ping(),
    }
    healthy = all(checks.values())
    return JSONResponse(
        status_code=200 if healthy else 503,
        content={"status": "ok" if healthy else "degraded", "checks": checks, "version": __version__},
    )
